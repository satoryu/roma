require 'test_helper'
require 'receiver_command_test_helper'

class VnodeCommandReceiverTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  # A vnode stream as spushv receives it: each key and value, and 20 zero
  # bytes at the end. A nil value is a deleted mark, whose expiry is 0.
  def stream(vnode, pairs)
    data = pairs.map do |k, v|
      [vnode, Time.now.to_i, 1, v ? 0x7fffffff : 0, k.bytesize, k, (v || '').bytesize,
       v || ''].pack("NNNNNa#{k.bytesize}Na*")
    end
    data.join + ("\0" * 20)
  end

  def test_spushv_protection
    assert_equal "false\r\n", @conn.request('spushv_protection')
    assert_equal "true\r\n", @conn.request('spushv_protection true')
    assert_true @conn.stats.spushv_protection
    assert_equal "false\r\n", @conn.request('spushv_protection no')
    assert_equal "COMMAND ERROR\r\n", @conn.request('spushv_protection true false')
  end

  def test_spushv
    reply = @conn.request('spushv roma 0', stream(0, 'key1' => 'value1', 'key2' => nil).chomp("\r\n"))
    assert_equal "READY\r\nSTORED\r\n", reply
    assert_equal 'value1', @conn.storage.get(0, 'key1', 0)
    # The deleted mark is stored, so get finds nothing.
    assert_nil @conn.storage.get(0, 'key2', 0)
    assert_not_nil @conn.storage.db_get(0, 'key2')
    # It stops the storage clean up, and is no longer receiving the vnode.
    assert_equal 1, @conn.server.clean_up_stops
    assert_equal({}, @conn.stats.run_receive_a_vnode)
  end

  def test_spushv_rejects_older_data
    @conn.storage.set(0, 'key1', 0, 0x7fffffff, 'newer')
    @conn.storage.set(0, 'key1', 0, 0x7fffffff, 'newer')
    @conn.request('spushv roma 0', stream(0, 'key1' => 'older'))
    assert_equal 'newer', @conn.storage.get(0, 'key1', 0)
  end

  def test_spushv_warns_about_long_keys_and_values
    @conn.stats.spushv_klength_warn = 1
    @conn.stats.spushv_vlength_warn = 1
    assert_equal "READY\r\nSTORED\r\n", @conn.request('spushv roma 0', stream(0, 'key1' => 'value1'))
  end

  def test_spushv_in_protection
    @conn.stats.spushv_protection = true
    assert_equal "SERVER_ERROR In spushv_protection.\r\n", @conn.request('spushv roma 0', stream(0, 'key1' => 'v'))
    assert_nil @conn.storage.get(0, 'key1', 0)
  end

  def test_spushv_wrong_number_of_arguments
    assert_equal "CLIENT_ERROR Wrong number of arguments.\r\n", @conn.request('spushv roma')
  end

  def test_spushv_to_a_new_hash
    @conn.stats.address = 'vnodecommandtest'
    @conn.stats.port = Process.pid.to_s
    assert_equal "READY\r\nSTORED\r\n", @conn.request('spushv newhash 0', stream(0, 'key1' => 'v'))
    assert_equal 'v', @conn.storages['newhash'].get(0, 'key1', 0)
  ensure
    @conn.storages['newhash']&.closedb
    FileUtils.rm_rf("#{Roma.config.storage.path}/#{@conn.stats.my_node_id}")
  end

  def test_reqpushv
    assert_equal "PUSHED\r\n", @conn.request("reqpushv 0 #{OTHER_NODE_ID} true")
    msg = Roma::AsyncProcess.queue.pop
    assert_equal ['reqpushv', ['0', OTHER_NODE_ID, 'true']], [msg.event, msg.args]
  end

  data('iterating storage' => :run_iterate_storage, 'joining' => :run_join, 'balancing' => :run_balance)
  def test_reqpushv_rejected(flag)
    @conn.stats.send("#{flag}=", true)
    assert_equal "REJECTED\r\n", @conn.request("reqpushv 0 #{OTHER_NODE_ID} true")
    assert_true Roma::AsyncProcess.queue.empty?
  end

  def test_reqpushv_usage
    assert_equal "CLIENT_ERROR usage:reqpushv vnode-id node-id primary-flag(true/false)\r\n",
                 @conn.request('reqpushv 0')
  end
end
