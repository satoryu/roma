require 'test_helper'
require 'roma/event/handler'

# Unit tests for how Roma::Event::Handler reads the data of a connection.
class HandlerTest < Test::Unit::TestCase
  def setup
    @handler = Roma::Event::Handler.allocate
    @handler.instance_variable_set(:@read_buffer, +'')
    @handler.instance_variable_set(:@connected, true)
  end

  # Runs the block, which reads, in a Fiber, as the dispatcher does, and
  # gives the handler +pieces+ one by one, as EventMachine does. Returns its
  # result.
  def read(pieces:, &)
    fiber = Fiber.new(&)
    pieces.each do |piece|
      @handler.instance_variable_get(:@read_buffer) << piece.b
      result = fiber.resume
      return result unless fiber.alive?
    end
    flunk 'it still waits'
  end

  def buffer = @handler.instance_variable_get(:@read_buffer)

  def test_read_bytes
    assert_equal 'abc', read(pieces: %w(abc)) { @handler.send(:read_bytes, 3) }
    assert_equal '', buffer
    assert_equal 'abc', read(pieces: %w(a bcde)) { @handler.send(:read_bytes, 3) }
    assert_equal 'de', buffer
  end

  def test_read_value
    assert_equal 'value', read(pieces: ["value\r\n"]) { @handler.send(:read_value, 5) }
    assert_equal '', buffer
    assert_equal 'value', read(pieces: ['val', "ue\r", "\nget k\r\n"]) { @handler.send(:read_value, 5) }
    assert_equal "get k\r\n", buffer
  end

  def test_read_value_waits_for_the_crlf
    assert_equal 'value', read(pieces: %W[value \r \n]) { @handler.send(:read_value, 5) }
  end

  def test_read_empty_value
    assert_equal '', read(pieces: ["\r\nnext"]) { @handler.send(:read_value, 0) }
    assert_equal 'next', buffer
  end

  def test_read_binary_value
    value = [0xff, 0, 0xe3, 0x81, 0x82].pack('C*')
    assert_equal value, read(pieces: [value[0, 3], "#{value[3..]}\r\nnext"]) { @handler.send(:read_value, 5) }
    assert_equal 'next', buffer
  end

  def test_gets
    assert_equal "get k\r\n", read(pieces: ['get', " k\r\nset"]) { @handler.send(:gets) }
    assert_equal 'set', buffer
  end

  # A line without a newline can't fill the memory.
  def test_gets_too_long
    Roma::Event::Handler.max_line_length = 10
    assert_raise_message('line too long') do
      read(pieces: ['get ', 'a' * 10, 'b']) { @handler.send(:gets) }
    end
  ensure
    Roma::Event::Handler.max_line_length = 1024 * 1024
  end

  # A value larger than the limit isn't read at all.
  def test_read_value_too_large
    Roma::Event::Handler.max_value_size = 4
    assert_equal 'abcd', read(pieces: ["abcd\r\n"]) { @handler.send(:read_value, 4) }
    assert_raise_message('object too large: 5 bytes') do
      read(pieces: ['']) { @handler.send(:read_value, 5) }
    end
    assert_raise(Roma::Event::Handler::RequestTooLarge) do
      read(pieces: ['']) { @handler.send(:read_stream_bytes, 5) }
    end
  ensure
    Roma::Event::Handler.max_value_size = 16 * 1024 * 1024
  end

  # It is replied, and the connection is closed after the reply, since the
  # rest of the request isn't read.
  def test_dispatcher_replies_a_request_too_large
    handler = Roma::Event::Handler.allocate
    replies = []
    closed = []
    handler.define_singleton_method(:gets) { raise Roma::Event::Handler::RequestTooLarge, 'line too long' }
    handler.define_singleton_method(:send_data) { |data| replies << data }
    handler.define_singleton_method(:close_connection_after_writing) { closed << :after_writing }
    handler.instance_variable_set(:@connected, true)
    handler.instance_variable_set(:@log, Logger.new(nil))
    handler.send(:dispatcher)
    assert_equal ["SERVER_ERROR line too long\r\n"], replies
    assert_equal [:after_writing], closed
  end
end
