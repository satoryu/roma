require 'logger'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'roma/stats'
require 'roma/command/receiver'
require 'roma/event/con_pool'
require 'roma/routing/cb_rttable'

# Runs ROMA's own commands (stat, balse, set_*/rset_* and so on) in-process,
# without romad or sockets.
#
# It stands in for Roma::Command::Receiver, the event handler that mixes in
# the command modules:
#
# - Replies are collected instead of sent.
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

  NID = 'localhost_11211'
  OTHER_NID = 'localhost_11212'

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

  # Stands in for $roma, the running romad.
  WriteBehindWriter = Struct.new(:shift_size)
  Romad = Struct.new(:wb_writer)

  attr_reader :stats, :rttable, :log, :romad, :broadcasts
  # What the other node answers to relayed commands.
  attr_accessor :relay_reply

  def initialize
    @stats = Roma::Stats.send(:new)
    @stats.address, @stats.port = NID.split('_')
    @nid = NID
    @defhash = 'roma'
    @log = Log.new
    @romad = Romad.new(WriteBehindWriter.new(nil))
    @storages = {}
    @dir = Dir.mktmpdir('roma_command')
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
  def request(line)
    @wbuf = String.new
    s = line.split(/ /)
    with_globals { send("ev_#{s[0]}", s) }
    @wbuf
  end

  def send_data(data)
    @wbuf << data
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
