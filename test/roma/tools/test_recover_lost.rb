require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/storage/hash'
require 'roma/tools/recover_lost'
require 'roma/configuration'

class RecoverLostTest < Test::Unit::TestCase
  include ToolTestHelper

  # Chooses the first node.
  class FirstNode
    def self.rand(_max)
      0
    end
  end

  def setup
    super
    @node = fake_node
    @node.replies['setroute'] = "STORED\r\n"
    @routing_data = Roma::Routing::RoutingData.create(32, 3, 1, [@node.node_id])
    serve_routing(@node, @routing_data)
    @storage = Roma::Storage::HashStorage.new
    @storage.vn_list = @routing_data.routes.keys
    @storage.each_vn_dump_sleep = 0
    @storage.opendb
    # A directory of a hash, as roma storage recover-lost finds in the storage path.
    FileUtils.mkdir_p(File.join(@dir, 'roma'))
    @out = StringIO.new
  end

  # The real one opens the storage files (dbm, sqlite3 or groonga).
  def tool(alist: false)
    tool = Roma::Tools::RecoverLost.new(out: @out, alist: alist, push_wait: 0, random: FirstNode)
    storage = @storage
    opened = @opened = []
    closed = @closed = []
    tool.define_singleton_method(:open_storage) { |dir, _vnodes| storage.tap { opened << dir } }
    storage.define_singleton_method(:closedb) { closed << :closed }
    tool
  end

  # Set twice, so that the clock is not 0.
  def store(key, value)
    d = Digest::SHA1.hexdigest(key).hex % (2**32)
    vnode = d & @routing_data.search_mask
    2.times { @storage.set(vnode, key, d, 0x7fffffff, value) }
    assert_equal 1, @storage.raw(vnode, key, d)[2]
    vnode
  end

  def lose(vnode)
    @routing_data.routes[vnode] = []
    serve_routing(@node, @routing_data)
    vnode
  end

  def test_recover_lost_vnodes
    vnode = lose(store('key1', 'value1'))
    tool.recover(@node.node_id, @dir)
    assert_match(
      %r{\A1 vnodes where data was lost\.\nroma #{@dir}/roma\n0/1 #{vnode} assign to \["#{@node.node_id}"\]\n\z}, @out.string
    )
    # The vnode is pushed to a node, and it is told to own the vnode.
    assert_equal ['key1'], @node.dat[vnode].keys
    # The clock of the data is reset.
    assert_equal [vnode, 0, 'value1'], @node.dat[vnode]['key1'].unpack('NNNNa*').values_at(0, 2, 4)
    assert_equal ["setroute #{vnode} 0 #{@node.node_id}"], @node.commands.grep(/\Asetroute/)
    assert_equal [File.join(@dir, 'roma')], @opened
    assert_equal [:closed], @closed
  end

  # The other nodes are told that the node now owns the vnode, even if one
  # of them is down.
  def test_tell_the_other_nodes
    other = fake_node
    down = down_node
    @routing_data.nodes.push(other.node_id, down)
    vnode = lose(store('key1', 'value1'))
    tool.recover(@node.node_id, @dir)
    assert_include other.commands, "setroute #{vnode} 0 #{@node.node_id}"
    assert_match(/^#{down}: .*refused/i, @out.string)
  end

  def test_setroute_refused
    @node.replies['setroute'] = "SERVER_ERROR busy\r\n"
    vnode = lose(store('key1', 'value1'))
    assert_raise_message("#{@node.node_id} replied to setroute #{vnode} 0 #{@node.node_id}: SERVER_ERROR busy") do
      tool.recover(@node.node_id, @dir)
    end
  end

  # A vnode that has a node now, but lost data since the time.
  def test_since
    vnode = store('key1', 'value1')
    @node.replies['history_of_lost'] = "#{vnode}\r\nEND\r\n"
    tool.recover(@node.node_id, @dir, since: '20260101000000')
    assert_include @node.commands, 'history_of_lost 20260101000000'
    assert_match(%r{^0/1 #{vnode} was auto assigned at \["#{@node.node_id}"\]$}, @out.string)
    assert_equal ['key1'], @node.dat[vnode].keys
    assert_empty @node.commands.grep(/\Asetroute/)
  end

  data('short' => '2026', 'not digits' => '2026010100000x')
  def test_since_format(since)
    assert_raise_message('The time should be YYYYMMDDHHMMSS.') { tool.recover(@node.node_id, @dir, since: since) }
    assert_empty @node.commands
  end

  def test_history_of_lost_error
    @node.replies['history_of_lost'] = "CLIENT_ERROR\r\n"
    assert_raise_message("#{@node.node_id} replied to history_of_lost: CLIENT_ERROR") do
      tool.recover(@node.node_id, @dir, since: '20260101000000')
    end
  end

  def test_nothing_lost
    tool.recover(@node.node_id, @dir)
    assert_equal "0 vnodes where data was lost.\n", @out.string
    assert_empty @opened
  end

  def test_all
    vnode = store('key1', 'value1')
    tool.recover(@node.node_id, @dir, all: true)
    assert_equal ['key1'], @node.dat[vnode].keys
    assert_equal @routing_data.routes.keys.sort, @node.dat.keys.sort
    assert_not_match(/vnodes where data was lost/, @out.string)
  end

  # The storage is closed even then.
  def test_push_failed
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    assert_raise_message("Pushing vnode 0 to #{@node.node_id} failed: SERVER_ERROR busy") do
      tool.recover(@node.node_id, @dir, all: true)
    end
    assert_equal [:closed], @closed
  end

  def test_alist
    @node.replies['alist_spushv'] = "SERVER_ERROR busy\r\n"
    assert_raise(Roma::Tools::Error) { tool(alist: true).recover(@node.node_id, @dir, all: true) }
    assert_equal ['alist_spushv roma 0'], @node.commands.grep(/spushv/)
  end

  def test_recover_keys
    vnode = store('key1', 'value1')
    lost = lose(store('キー', 'value2'))
    tool.recover_keys(@node.node_id, @dir, %w(key1 key2 キー))
    assert_equal "roma #{@dir}/roma\nhit => key1\n#{@node.node_id}=>STORED\nhit => キー\n", @out.string
    assert_equal ['key1'], @node.dat[vnode].keys
    # The data is pushed with the clock reset.
    assert_equal [vnode, 0, 0x7fffffff, 'value1'], @node.dat[vnode]['key1'].unpack('NNNNa*').values_at(0, 2, 3, 4)
    assert_nil @node.dat[lost]
  end

  # A multibyte key is packed by its bytes.
  def test_recover_multibyte_key
    vnode = store('キー', '値')
    tool.recover_keys(@node.node_id, @dir, ['キー'])
    assert_equal ['キー'.b], @node.dat[vnode].keys
  end

  def test_recover_keys_refused
    store('key1', 'value1')
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    tool.recover_keys(@node.node_id, @dir, ['key1'])
    assert_match(/^#{@node.node_id}=>SERVER_ERROR busy$/, @out.string)
  end

  def test_no_directories
    FileUtils.rm_rf(File.join(@dir, 'roma'))
    assert_raise_message("#{@dir} has no directories of storage files.") do
      tool.recover(@node.node_id, @dir, all: true)
    end
  end

  def test_node_down
    assert_raise_message(/\Alocalhost_1: /) { tool.recover('localhost_1', @dir) }
  end
end
