require 'digest/sha1'
require 'roma/storage/ruby_hash_storage'
require 'roma/command/util_command_receiver'

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

  Stats = Struct.new(:wb_command_map, :read_count, :write_count, :delete_count)

  class RoutingTable
    def hbits
      2**32
    end

    def get_vnode_id(_digest)
      0
    end

    def search_nodes_for_write(_vn)
      [NID, REPLICA_NID]
    end
  end

  def self.for(*plugins)
    Class.new(self) { plugins.each { |plugin| include plugin } }
  end

  attr_reader :stats, :storage, :redundant_calls

  def initialize
    @nid = NID
    @defhash = HASH_NAME
    @rttable = RoutingTable.new
    @stats = Stats.new({}, 0, 0, 0)
    @storage = Roma::Storage::RubyHashStorage.new
    @storage.vn_list = [0]
    @storage.opendb
    @storages = { HASH_NAME => @storage }
    @redundant_calls = []
  end

  # Runs a command line (without "\r\n") and returns everything it replied.
  # +data+ is the data block that follows the command line, if any.
  def request(line, data = nil)
    @rbuf = data ? "#{data}\r\n" : String.new
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

  def redundant(nodes, hname, k, d, clk, expt, v)
    @redundant_calls << { nodes: nodes, hname: hname, key: k, expt: expt, value: v }
  end
end
