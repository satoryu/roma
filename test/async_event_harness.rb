require 'logger'
require 'tmpdir'
require 'fileutils'
require 'roma/stats'
require 'roma/async_event'
require 'roma/messaging/connection_pool'
require 'roma/routing/churnbased_routing_table'
require 'roma/storage/hash'

# Runs the async events of the server (Roma::AsyncEvent) in-process.
#
# - A fresh Roma::Stats and a real routing table are made for each harness.
#   This node is NODE_ID; +nodes+ are the nodes in the routing table.
# - The roma hash is a HashStorage.
# - Commands sent to one node (async_send_cmd) or to all (async_broadcast_cmd)
#   are recorded and answered with +send_cmd_reply+. Pushing a vnode
#   (push_a_vnode_stream, req_push_a_vnode) really connects to the node, so
#   tests use a FakeNode for it.
# - sleep only records how long it would have slept, so that the processes,
#   which sleep between steps, run fast.
#
#   h = AsyncEventHarness.new
#   h.call(:asyncev_rdelete, [OTHER_NODE_ID, 'roma', 'key', 1]) # => true
#   h.sent # => [["localhost_11212", "rdelete key\eroma 1\r\n"]]
class AsyncEventHarness
  include Roma::AsyncEvent

  NODE_ID = 'localhost_11211'
  OTHER_NODE_ID = 'localhost_11212'

  attr_reader :stats, :routing_table, :storages, :storage, :sent, :broadcasts, :slept, :dir
  attr_accessor :send_cmd_reply

  def initialize(nodes: [NODE_ID, OTHER_NODE_ID], vnode_nodes: nil)
    @log = Logger.new(nil)
    @stats = Roma::Stats.send(:new)
    @stats.address, @stats.port = NODE_ID.split('_')
    @dir = Dir.mktmpdir('roma_async')
    routing_data = Roma::Routing::RoutingData.create(32, 3, 2, nodes)
    # Choose the nodes of every vnode, instead of at random.
    routing_data.routes.each_key { |vnode| routing_data.routes[vnode] = vnode_nodes.dup } if vnode_nodes
    @routing_table = Roma::Routing::ChurnbasedRoutingTable.new(routing_data, File.join(@dir, 'test.route.yml'))
    @storage = Roma::Storage::HashStorage.new
    @storage.vn_list = routing_data.routes.keys
    @storage.storage_path = @dir
    @storage.st_class = Roma::Storage::HashStorage
    @storage.each_vn_dump_sleep = 0
    @storage.each_clean_up_sleep = 0
    @storage.opendb
    @storages = { 'roma' => @storage }
    @sent = []
    @broadcasts = []
    @slept = []
    @send_cmd_reply = "STORED\r\n"
  end

  def close
    @routing_table.close_log
    FileUtils.rm_rf(@dir)
  end

  # Calls a private method of Roma::AsyncEvent.
  def call(name, *)
    send(name, *)
  end

  # Stores +value+ under +key+ in the vnode the key belongs to, and returns
  # the vnode.
  def store(key, value, expire_time: 0x7fffffff)
    d = Digest::SHA1.hexdigest(key).hex % @routing_table.hash_space_size
    vnode = @routing_table.get_vnode_id(d)
    @storage.set(vnode, key, d, expire_time, value)
    vnode
  end

  def async_send_cmd(node_id, cmd, _tout = nil)
    @sent << [node_id, cmd]
    @send_cmd_reply
  end

  def async_broadcast_cmd(cmd, _without_nids = nil, _tout = nil)
    @broadcasts << cmd
    {}
  end

  def stop_clean_up; end

  private

  def sleep(sec = nil)
    @slept << sec
    Thread.pass
  end
end
