require 'digest/sha1'
require 'logger'
require 'stringio'
require 'roma/storage/ruby_hash_storage'
require 'roma/command/util_command_receiver'
require 'roma/routing/routing_data'
require 'roma_test_client'

# Runs command plugins in-process, without romad or sockets.
#
# It stands in for the event handler: commands are dispatched to ev_* methods,
# replies are collected instead of sent, and data is stored in a
# RubyHashStorage. Every key is routed to +nodes+ (this node first, unless
# given), and replication is recorded instead of sent to other nodes.
#
#   conn = PluginTestHarness.for(Roma::CommandPlugin::PluginMap).new
#   conn.request('map_set key1 mapkey1 0 0 6', 'value1') # => "STORED\r\n"
#
# To test forwarding, make two harnesses: one for the node that has every
# key, and one that forwards commands to it.
#
#   klass = PluginTestHarness.for(Roma::CommandPlugin::PluginStorage)
#   owner = klass.new(nid: PluginTestHarness::REPLICA_NID, nodes: [REPLICA_NID, NID])
#   conn = klass.new(nodes: [REPLICA_NID, NID]).forward_to(owner)
#   conn.request('get key1') # forwarded to owner
class PluginTestHarness
  include Roma::Command::UtilCommandReceiver

  NID = 'localhost_11211'
  REPLICA_NID = 'localhost_11212'
  HASH_NAME = 'roma'

  Stats = Struct.new(:wb_command_map, :read_count, :write_count, :delete_count,
                     :size_of_zredundant, :ap_str)

  # Stands in for $roma, the running romad, which some commands look at.
  Romad = Struct.new(:cr_writer)
  ClusterReplicationWriter = Struct.new(:run_replication)

  class RoutingTable
    attr_reader :nodes, :failed

    def initialize(nodes)
      @nodes = nodes
      @failed = []
    end

    def hbits
      2**32
    end

    def get_vnode_id(_digest)
      0
    end

    def search_nodes(_vn)
      @nodes.dup
    end
    alias search_nodes_for_write search_nodes

    def proc_failed(nid)
      @failed << nid
    end

    def proc_succeed(_nid); end
  end

  # Methods that would talk to other nodes. They are prepended so that they
  # win over the plugins' own definitions (e.g. PluginStorage#redundant).
  module Stubs
    def redundant(nodes, hname, k, d, clk, expt, v)
      @redundant_calls << { nodes: nodes, hname: hname, key: k, expt: expt, value: v }
    end

    # Without an owner to forward to, only replicas are sent commands.
    def send_cmd(nid, cmd)
      return super if @owner
      raise "unexpected command to #{nid}: #{cmd}" unless cmd.start_with?('rdelete ')
      @sent_commands << [nid, cmd]
      'DELETED'
    end
  end

  def self.for(*plugins)
    Class.new(self) do
      plugins.each { |plugin| include plugin }
      prepend Stubs
    end
  end

  attr_reader :stats, :storage, :storages, :redundant_calls, :sent_commands

  def initialize(nid: NID, nodes: [NID, REPLICA_NID])
    @romad = Romad.new(ClusterReplicationWriter.new(false))
    @nid = nid
    @defhash = HASH_NAME
    @rttable = RoutingTable.new(nodes)
    @stats = Stats.new({}, 0, 0, 0, 0, nid)
    @log = Logger.new(nil)
    @storage = Roma::Storage::RubyHashStorage.new
    @storage.vn_list = [0]
    @storage.opendb
    @storages = { HASH_NAME => @storage }
    @redundant_calls = []
    @sent_commands = []
  end

  # Runs a command line (without "\r\n") and returns everything it replied.
  # +data+ is the data block that follows the command line, if any.
  def request(line, data = nil)
    dispatch(line, data ? "#{data}\r\n" : String.new)
  end

  # Like #request, but +rest+ is the raw input after the command line.
  def dispatch(line, rest)
    @rbuf = rest.dup
    @wbuf = String.new
    s = line.split(/ /)
    # Set $roma only while the command runs, so it doesn't leak into other tests.
    saved_romad = defined?($roma) ? $roma : nil
    $roma = @romad
    begin
      send("ev_#{s[0]}", s)
    ensure
      $roma = saved_romad
    end
    @wbuf
  end

  def send_data(data)
    @wbuf << data
  end

  def read_bytes(size)
    @rbuf.slice!(0, size)
  end

  # Sends the commands this node forwards to +owner+, another harness.
  # Without it, connecting to another node fails.
  def forward_to(owner)
    @owner = owner
    self
  end

  def get_connection(_nid)
    raise 'no connection' unless @owner
    NodeConnection.new(@owner)
  end

  def return_connection(_nid, _con); end

  # A connection to another node, as the event handler's connection pool
  # gives (send, gets, read_bytes), that sends each command to a harness.
  class NodeConnection
    def initialize(harness)
      @harness = harness
      @out = StringIO.new
    end

    def send(data)
      line, rest = data.split("\r\n", 2)
      @out = StringIO.new(@harness.dispatch(line, rest || String.new))
    end

    def gets
      @out.gets
    end

    def read_bytes(size)
      @out.read(size)
    end

    def close_connection; end
  end

  # A socket-like object that sends each write to a PluginTestHarness.
  class Connection
    def initialize(harness)
      @harness = harness
      @out = StringIO.new
    end

    def write(str)
      line, rest = str.split("\r\n", 2)
      @out = StringIO.new(@harness.dispatch(line, rest || String.new))
    end

    def gets
      @out.gets
    end

    def read(len)
      @out.read(len)
    end

    def close; end
  end

  # A RomaTestClient whose requests go to a PluginTestHarness, so tests written
  # for romad can run in-process.
  class Client < RomaTestClient
    def initialize(harness)
      @default_hash_name = HASH_NAME
      @used_keys = []
      @connection = Connection.new(harness)
      @rttable = RomaTestClient::RoutingTable.new(Roma::Routing::RoutingData.create(32, 3, 2, [NID, REPLICA_NID]))
    end

    private

    def connection(_nid)
      @connection
    end

    def close_connection(_nid); end
  end
end
