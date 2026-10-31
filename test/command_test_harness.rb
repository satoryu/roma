require 'logger'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'roma/stats'
require 'roma/command/receiver'
require 'roma/event/con_pool'
require 'roma/routing/cb_rttable'
require 'roma/storage/ruby_hash_storage'

# Runs ROMA's own commands (stat, balse, set_*/rset_*, the routing, vnode,
# background and multi-hash commands and so on) in-process, without romad
# or sockets.
#
# It stands in for Roma::Command::Receiver, the event handler that mixes in
# the command modules:
#
# - Replies are collected instead of sent. The connection isn't closed, and
#   the event loop isn't stopped; the harness records that they would be.
# - Commands relayed to the other nodes (broadcast_cmd) are recorded and
#   answered with +relay_reply+.
# - A fresh Roma::Stats and a real routing table of two nodes are made for
#   each harness, so tests don't share settings.
# - $roma (the running romad) and the command lists of Roma::Event::Handler
#   are replaced only while a command runs.
#
#   conn = CommandTestHarness.new
#   conn.request('set_hilatency_warn_time 3') # => "{...}\r\n"
#   conn.stats.hilatency_warn_time            # => 3.0
#   conn.broadcasts                           # => ["rset_hilatency_warn_time 3\r\n"]
#   conn.close
class CommandTestHarness
  include Roma::Command::UtilCommandReceiver
  include Roma::Command::SystemCommandReceiver
  include Roma::Command::RoutingCommandReceiver
  include Roma::Command::BackgroundCommandReceiver
  include Roma::Command::MultiHashCommandReceiver

  NID = 'localhost_11211'
  OTHER_NID = 'localhost_11212'
  # The address the client connects from.
  CLIENT_ADDR = '127.0.0.1'

  # Commands that clients may send, and the system commands among them.
  # Some commands accept only clients' commands as arguments.
  EV_LIST = { 'get' => :ev_get, 'set' => :ev_set, 'delete' => :ev_delete, 'balse' => :ev_balse }
  SYSTEM_COMMANDS = { 'balse' => nil }

  # A logger that also remembers what the commands set on RLogger.
  class Log < ::Logger
    attr_reader :shift_size, :shift_age

    def initialize
      super(nil)
    end

    def set_log_shift_size(size)
      @shift_size = size
    end

    def set_log_shift_age(age)
      @shift_age = age
    end
  end

  WriteBehindWriter = Struct.new(:shift_size)

  # Stands in for the writer of cluster replication. update_* would ask a
  # node of the replica cluster; here they just make up the answers.
  class ClusterReplicationWriter
    attr_accessor :run_replication, :run_existing_data_replication,
                  :replica_mklhash, :replica_nodelist, :replica_rttable

    def initialize
      @run_replication = false
      @run_existing_data_replication = false
      @replica_nodelist = []
    end

    def update_mklhash(nid)
      @replica_mklhash = "mklhash of #{nid}"
    end

    def update_nodelist(nid)
      @replica_nodelist = [nid]
    end

    def update_rttable(nid)
      @replica_rttable = "rttable of #{nid}"
    end
  end

  # Stands in for $roma, the running romad.
  class Romad
    attr_accessor :wb_writer, :cr_writer, :eventloop, :startup
    # Write-behind files open now, by hash name.
    attr_reader :wb_current_files, :rotated
    # How many times the storage clean up was stopped.
    attr_reader :clean_up_stops

    def initialize
      @wb_writer = WriteBehindWriter.new(nil)
      @cr_writer = ClusterReplicationWriter.new
      @startup = true
      @wb_current_files = {}
      @rotated = []
      @clean_up_stops = 0
    end

    def stop_clean_up
      @clean_up_stops += 1
    end

    def wb_rotate(hname)
      @rotated << hname
      !!@wb_current_files.delete(hname)
    end

    def wb_get_path(hname)
      "wb/#{NID}/#{hname}"
    end

    def wb_get_current_file_path(hname)
      @wb_current_files[hname]
    end

    def wb_get_stat
      { 'write-behind.run_replication' => @cr_writer.run_replication }
    end
  end

  attr_reader :stats, :rttable, :log, :romad, :broadcasts, :storage, :storages
  # How the last command closed the connection: :after_writing, :now or nil.
  attr_reader :closed
  # What the other node answers to relayed commands.
  attr_accessor :relay_reply

  def initialize
    @stats = Roma::Stats.send(:new)
    @stats.address, @stats.port = NID.split('_')
    @nid = NID
    @addr = CLIENT_ADDR
    @defhash = 'roma'
    @log = Log.new
    @romad = Romad.new
    @dir = Dir.mktmpdir('roma_command')
    @storage = Roma::Storage::RubyHashStorage.new
    @storage.vn_list = [0]
    @storage.storage_path = @dir
    @storage.st_class = Roma::Storage::RubyHashStorage
    @storage.opendb
    @storages = { @defhash => @storage }
    rd = Roma::Routing::RoutingData.create(32, 3, 2, [NID, OTHER_NID])
    @rttable = Roma::Routing::ChurnbasedRoutingTable.new(rd, File.join(@dir, 'test.route'))
    @broadcasts = []
    @relay_reply = 'STORED'
  end

  def close
    @rttable.close_log
    FileUtils.rm_rf(@dir)
  end

  # Runs a command line (without "\r\n") and returns everything it replied.
  # +data+ is what the client sends after the command line, if any: a data
  # block or the answer to a question.
  def request(line, data = nil)
    @rbuf = data ? "#{data}\r\n".b : String.new
    @wbuf = String.new
    @closed = nil
    s = line.split(/ /)
    with_globals { send("ev_#{s[0]}", s) }
    @wbuf
  end

  def send_data(data)
    @wbuf << data
  end

  def read_bytes(size, _timeout = nil)
    @rbuf.slice!(0, size)
  end

  # Returns nil when the client sent nothing more. The real one waits.
  def gets
    idx = @rbuf.index("\n")
    @rbuf.slice!(0, idx + 1) if idx
  end

  def close_connection_after_writing
    @closed = :after_writing
  end

  def close_connection
    @closed = :now
  end

  # Whether romad would stop when this connection closes.
  def stop_event_loop?
    !!@stop_event_loop
  end

  # The real one, in Event::Handler, asks EventMachine about connections.
  def conn_get_stat
    { 'connection.count' => 0 }
  end

  def broadcast_cmd(cmd)
    @broadcasts << cmd
    { OTHER_NID => @relay_reply }
  end

  private

  def with_globals
    saved_romad = defined?($roma) ? $roma : nil
    saved_ev_list = Roma::Event::Handler.ev_list.dup
    saved_system_commands = Roma::Event::Handler.system_commands.dup
    $roma = @romad
    Roma::Event::Handler.ev_list.replace(EV_LIST)
    Roma::Event::Handler.system_commands.replace(SYSTEM_COMMANDS)
    yield
  ensure
    $roma = saved_romad
    Roma::Event::Handler.ev_list.replace(saved_ev_list)
    Roma::Event::Handler.system_commands.replace(saved_system_commands)
  end
end
