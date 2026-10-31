require 'logger'
require 'tmpdir'
require 'fileutils'
require 'roma/stats'
require 'roma/async_process'
require 'roma/messaging/con_pool'
require 'roma/routing/cb_rttable'
require 'roma/storage/ruby_hash_storage'

# Runs the background processes of romad (Roma::AsyncProcess) in-process.
#
# - A fresh Roma::Stats and a real routing table are made for each harness.
#   This node is NID; +nodes+ are the nodes in the routing table.
# - The roma hash is a RubyHashStorage.
# - Commands sent to one node (async_send_cmd) or to all (async_broadcast_cmd)
#   are recorded and answered with +send_cmd_reply+. Pushing a vnode
#   (push_a_vnode_stream, req_push_a_vnode) really connects to the node, so
#   tests use a FakeNode for it.
# - sleep only records how long it would have slept, so that the processes,
#   which sleep between steps, run fast.
#
#   h = AsyncProcessHarness.new
#   h.call(:asyncev_rdelete, [OTHER_NID, 'roma', 'key', 1]) # => true
#   h.sent # => [["localhost_11212", "rdelete key\eroma 1\r\n"]]
class AsyncProcessHarness
  include Roma::AsyncProcess

  NID = 'localhost_11211'
  OTHER_NID = 'localhost_11212'

  attr_reader :stats, :rttable, :storages, :storage, :sent, :broadcasts, :slept, :dir
  attr_accessor :send_cmd_reply

  def initialize(nodes: [NID, OTHER_NID], vnode_nodes: nil)
    @log = Logger.new(nil)
    @stats = Roma::Stats.send(:new)
    @stats.address, @stats.port = NID.split('_')
    @dir = Dir.mktmpdir('roma_async')
    rd = Roma::Routing::RoutingData.create(32, 3, 2, nodes)
    # Choose the nodes of every vnode, instead of at random.
    rd.v_idx.each_key { |vn| rd.v_idx[vn] = vnode_nodes.dup } if vnode_nodes
    @rttable = Roma::Routing::ChurnbasedRoutingTable.new(rd, File.join(@dir, 'test.route'))
    @storage = Roma::Storage::RubyHashStorage.new
    @storage.vn_list = rd.v_idx.keys
    @storage.storage_path = @dir
    @storage.st_class = Roma::Storage::RubyHashStorage
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
    @rttable.close_log
    FileUtils.rm_rf(@dir)
  end

  # Calls a private method of Roma::AsyncProcess.
  def call(name, *args)
    send(name, *args)
  end

  # Stores +value+ under +key+ in the vnode the key belongs to, and returns
  # the vnode.
  def store(key, value, expt: 0x7fffffff)
    d = Digest::SHA1.hexdigest(key).hex % @rttable.hbits
    vn = @rttable.get_vnode_id(d)
    @storage.set(vn, key, d, expt, value)
    vn
  end

  def async_send_cmd(nid, cmd, _tout = nil)
    @sent << [nid, cmd]
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
