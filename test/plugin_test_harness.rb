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
# RubyHashStorage. Every key is routed to this node, so commands are never
# forwarded. Replication is recorded instead of sent to other nodes.
#
#   conn = PluginTestHarness.for(Roma::CommandPlugin::PluginMap).new
#   conn.request('map_set key1 mapkey1 0 0 6', 'value1') # => "STORED\r\n"
class PluginTestHarness
  include Roma::Command::UtilCommandReceiver

  NID = 'localhost_11211'
  REPLICA_NID = 'localhost_11212'
  HASH_NAME = 'roma'

  Stats = Struct.new(:wb_command_map, :read_count, :write_count, :delete_count,
                     :size_of_zredundant)

  # Stands in for $roma, the running romad, which some commands look at.
  Romad = Struct.new(:cr_writer)
  ClusterReplicationWriter = Struct.new(:run_replication)

  class RoutingTable
    def hbits
      2**32
    end

    def get_vnode_id(_digest)
      0
    end

    def search_nodes(_vn)
      [NID, REPLICA_NID]
    end
    alias search_nodes_for_write search_nodes
  end

  # Methods that would talk to other nodes. They are prepended so that they
  # win over the plugins' own definitions (e.g. PluginStorage#redundant).
  module Stubs
    def redundant(nodes, hname, k, d, clk, expt, v)
      @redundant_calls << { nodes: nodes, hname: hname, key: k, expt: expt, value: v }
    end

    # Only replicas are sent commands, since every key belongs to this node.
    def send_cmd(nid, cmd)
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

  attr_reader :stats, :storage, :redundant_calls, :sent_commands

  def initialize
    $roma ||= Romad.new(ClusterReplicationWriter.new(false))
    @nid = NID
    @defhash = HASH_NAME
    @rttable = RoutingTable.new
    @stats = Stats.new({}, 0, 0, 0, 0)
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
    send("ev_#{s[0]}", s)
    @wbuf
  end

  def send_data(data)
    @wbuf << data
  end

  def read_bytes(size)
    @rbuf.slice!(0, size)
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
