require 'test_helper'
require 'tool_test_helper'
require 'fake_kvs'
require 'roma/tools/text_client'

class TextClientTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
    @client = Roma::Tools::TextClient.new([@kvs.nid], timeout: 0.5)
  end

  def teardown
    @client.close
    super
  end

  def test_set_get_delete
    assert_equal 'STORED', @client.set('key1', "va\r\nlue")
    assert_equal "va\r\nlue", @client.get('key1')
    assert_equal 'DELETED', @client.delete('key1')
    assert_nil @client.get('key1')
    assert_equal 'NOT_FOUND', @client.delete('key1')
    # One connection.
    assert_equal ['set key1 0 0 7', 'get key1', 'delete key1', 'get key1', 'delete key1'], @kvs.commands
  end

  def test_multibyte_value
    @client.set('key1', '値')
    assert_equal '値'.b, @client.get('key1')
  end

  def test_expt
    @client.set('key1', 'v', 100)
    assert_equal 'set key1 0 100 1', @kvs.commands[0]
  end

  def test_get_error
    @kvs.replies['get'] = "SERVER_ERROR busy\r\n"
    assert_raise_message('get key1: SERVER_ERROR busy') { @client.get('key1') }
  end

  def test_get_without_end
    @kvs.replies['get'] = "VALUE key1 0 1\r\nv\r\nVALUE\r\n"
    assert_raise_message('get key1: VALUE') { @client.get('key1') }
  end

  # The node may read the value as a command, so the connection is closed.
  data('set' => ['set', ->(c) { c.set('key1', 'v') }, 'set key1: ERROR'],
       'delete' => ['delete', ->(c) { c.delete('key1') }, 'delete key1: ERROR'])
  def test_unexpected_reply(data)
    name, call, message = data
    @kvs.replies[name] = "ERROR\r\n"
    assert_raise_message(message) { call.call(@client) }
    @kvs.replies.clear
    assert_equal 'STORED', @client.set('key2', 'v')
    assert_equal 2, @kvs.commands.size
  end

  def test_not_stored
    @kvs.replies['set'] = "NOT_STORED\r\n"
    assert_equal 'NOT_STORED', @client.set('key1', 'v')
  end

  def test_closed
    @kvs.replies['set'] = :close
    assert_raise_message('The connection was closed.') { @client.set('key1', 'v') }
  end

  def test_no_reply
    @kvs.replies['delete'] = ''
    assert_raise_message(/execution expired/) { @client.delete('key1') }
  end

  # The next node is used after an error.
  def test_next_node
    down = down_node
    client = Roma::Tools::TextClient.new([down, @kvs.nid], timeout: 0.5)
    assert_raise_message(/\A#{down}: /) { client.set('key1', 'v') }
    assert_equal 'STORED', client.set('key1', 'v')
  ensure
    client.close
  end

  def test_no_node
    assert_raise_message('No node is given.') { Roma::Tools::TextClient.new([]) }
  end
end
