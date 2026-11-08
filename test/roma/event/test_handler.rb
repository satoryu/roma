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
end
