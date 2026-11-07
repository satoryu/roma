require 'logger'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'roma/stats'
require 'roma/command/receiver'
require 'roma/event/em_connection_pool'
require 'roma/routing/churnbased_routing_table'
require 'roma/storage/hash'

# Runs ROMA's own commands (stat, balse, set_*/rset_*, the routing, vnode,
# background and multi-hash commands and so on) in-process, without a server
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
# - $roma (the running server) and the command lists of Roma::Event::Handler
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

  NODE_ID = 'localhost_11211'
  OTHER_NODE_ID = 'localhost_11212'
  # The address the client connects from.
  CLIENT_ADDR = '127.0.0.1'

  # Commands that clients may send, and the system commands among them.
  # Some commands accept only clients' commands as arguments.
  EVENT_LIST = { 'get' => :ev_get, 'set' => :ev_set, 'delete' => :ev_delete, 'balse' => :ev_balse }
  SYSTEM_COMMANDS = { 'balse' => nil }

  # A logger that also remembers what the commands set on RLogger.
  class Log < ::Logger
    attr_accessor :shift_size, :shift_age

    def initialize
      super(nil)
    end
  end

  # Stands in for the writer of the write-behind files.
  class WriteBehindWriter
    attr_accessor :shift_size
    # Files open now, by hash name.
    attr_reader :current_files, :rotated

    def initialize
      @current_files = {}
      @rotated = []
    end

    def rotate(hash_name)
      @rotated << hash_name
      !!@current_files.delete(hash_name)
    end

    def path(hash_name)
      "wb/#{NODE_ID}/#{hash_name}"
    end

    def current_file_path(hash_name)
      @current_files[hash_name]
    end
  end

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

    def update_mklhash(node_id)
      @replica_mklhash = "mklhash of #{node_id}"
    end

    def update_nodelist(node_id)
      @replica_nodelist = [node_id]
    end

    def update_rttable(node_id)
      @replica_rttable = "routing_table of #{node_id}"
    end
  end

  # Stands in for $roma, the running server.
  class Server
    attr_accessor :wb_writer, :cluster_replication_writer, :eventloop, :startup
    # How many times the storage clean up was stopped.
    attr_reader :clean_up_stops

    def initialize
      @wb_writer = WriteBehindWriter.new
      @cluster_replication_writer = ClusterReplicationWriter.new
      @startup = true
      @clean_up_stops = 0
    end

    def stop_clean_up
      @clean_up_stops += 1
    end

    def write_behind_stat
      { 'write-behind.run_replication' => @cluster_replication_writer.run_replication }
    end
  end

  attr_reader :stats, :routing_table, :log, :server, :broadcasts, :storage, :storages
  # How the last command closed the connection: :after_writing, :now or nil.
  attr_reader :closed
  # What the other node answers to relayed commands.
  attr_accessor :relay_reply

  def initialize
    @stats = Roma::Stats.send(:new)
    @stats.address, @stats.port = NODE_ID.split('_')
    @my_node_id = NODE_ID
    @addr = CLIENT_ADDR
    @default_hash_name = 'roma'
    @log = Log.new
    @server = Server.new
    @dir = Dir.mktmpdir('roma_command')
    @storage = Roma::Storage::HashStorage.new
    @storage.vn_list = [0]
    @storage.storage_path = @dir
    @storage.st_class = Roma::Storage::HashStorage
    @storage.opendb
    @storages = { @default_hash_name => @storage }
    routing_data = Roma::Routing::RoutingData.create(32, 3, 2, [NODE_ID, OTHER_NODE_ID])
    @routing_table = Roma::Routing::ChurnbasedRoutingTable.new(routing_data, File.join(@dir, 'test.route.yml'))
    @broadcasts = []
    @relay_reply = 'STORED'
  end

  def close
    @routing_table.close_log
    FileUtils.rm_rf(@dir)
  end

  # Runs a command line (without "\r\n") and returns everything it replied.
  # +data+ is what the client sends after the command line, if any: a data
  # block or the answer to a question.
  def request(line, data = nil)
    @read_buffer = data ? "#{data}\r\n".b : String.new
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
    @read_buffer.slice!(0, size)
  end

  # Returns nil when the client sent nothing more. The real one waits.
  def gets
    idx = @read_buffer.index("\n")
    @read_buffer.slice!(0, idx + 1) if idx
  end

  def close_connection_after_writing
    @closed = :after_writing
  end

  def close_connection
    @closed = :now
  end

  # Whether the server would stop when this connection closes.
  def stop_event_loop?
    !!@stop_event_loop
  end

  # The real one, in Event::Handler, asks EventMachine about connections.
  def conn_get_stat
    { 'connection.count' => 0 }
  end

  def broadcast_cmd(cmd)
    @broadcasts << cmd
    { OTHER_NODE_ID => @relay_reply }
  end

  private

  def with_globals
    saved_server = defined?($roma) ? $roma : nil
    saved_event_list = Roma::Event::Handler.event_list.dup
    saved_system_commands = Roma::Event::Handler.system_commands.dup
    $roma = @server
    Roma::Event::Handler.event_list.replace(EVENT_LIST)
    Roma::Event::Handler.system_commands.replace(SYSTEM_COMMANDS)
    yield
  ensure
    $roma = saved_server
    Roma::Event::Handler.event_list.replace(saved_event_list)
    Roma::Event::Handler.system_commands.replace(saved_system_commands)
  end
end
