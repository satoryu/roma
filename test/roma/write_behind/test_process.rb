require 'test_helper'
require 'logger'
require 'roma/write_behind/process'

class WriteBehindProcessTest < Test::Unit::TestCase
  # Records what it is given.
  class Recorder
    attr_reader :calls

    def initialize = @calls = Queue.new

    def write(*args) = @calls << args

    def transmit(*args) = @calls << args
  end

  class Server
    include Roma::WriteBehind::Process

    def initialize(wb_writer, cluster_replication_writer)
      @wb_writer = wb_writer
      @cluster_replication_writer = cluster_replication_writer
      @log = Logger.new(nil)
    end
  end

  # An item with a hash name goes to the write-behind files, and one without
  # to the replica cluster only: write-behind can't write a command line.
  def test_process_loop
    wb = Recorder.new
    replica = Recorder.new
    thread = Thread.new { Server.new(wb, replica).send(:process_loop) }
    Roma::WriteBehind::Process.push('roma', 1, 'key', 'value')
    Roma::WriteBehind::Process.push(nil, "set key 0 0 5\r\nvalue\r\n", 'key', 'value')
    assert_equal ['roma', 1, 'key', 'value'], wb.calls.pop
    assert_equal ["set key 0 0 5\r\nvalue\r\n", 'key', 'value'], replica.calls.pop
    sleep 0.05
    assert_true wb.calls.empty?
  ensure
    thread&.kill
  end
end
