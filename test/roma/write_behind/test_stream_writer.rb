require 'test_helper'
require 'logger'
require 'stringio'
require 'roma/write_behind/stream_writer'

# StreamWriter with a pool whose connections answer from a Hash, instead of
# the nodes of a replica cluster.
class StreamWriterTest < Test::Unit::TestCase
  class Pool
    attr_reader :checkins

    # +replies+ are the lines that each node answers, or nil for a node down.
    def initialize(replies)
      @replies = replies
      @checkins = []
    end

    def checkout(node_id)
      reply = @replies.fetch(node_id)
      raise Errno::ECONNREFUSED unless reply

      Connection.new(reply)
    end

    def checkin(node_id, _con)
      @checkins << node_id
    end
  end

  class Connection
    def initialize(reply)
      @in = StringIO.new(reply)
    end

    def write(_data); end

    def gets
      @in.gets
    end

    def read(length)
      @in.read(length)
    end

    def close; end
  end

  def writer(replies)
    @pool = Pool.new(replies)
    Roma::WriteBehind::StreamWriter.new(Logger.new(nil), pool: @pool)
  end

  def test_update_mklhash
    sw = writer('replica_1' => "abc\r\n")
    sw.update_mklhash('replica_1')
    assert_equal 'abc', sw.replica_mklhash
    assert_equal ['replica_1'], @pool.checkins
  end

  # The routing table is read in the binary format, not by Marshal.
  def test_update_rttable
    routing_data = Roma::Routing::RoutingData.create(32, 3, 1, %w(replica_1))
    dump = routing_data.dump_binary
    sw = writer('replica_1' => "#{dump.bytesize}\r\n#{dump}\r\nEND\r\n")
    sw.update_rttable('replica_1')
    assert_equal routing_data.routes, sw.replica_rttable.routes
  end

  def test_update_rttable_with_marshal
    dump = Marshal.dump(Roma::Routing::RoutingData.create(32, 3, 1, %w(replica_1)))
    sw = writer('replica_1' => "#{dump.bytesize}\r\n#{dump}\r\nEND\r\n")
    sw.update_rttable('replica_1')
    assert_nil sw.replica_rttable
  end

  # A node that is down is dropped, and the next one is asked.
  def test_change_mklhash
    sw = writer('replica_1' => nil, 'replica_2' => "new\r\n")
    sw.instance_variable_set(:@replica_nodelist, %w(replica_1 replica_2))
    sw.instance_variable_set(:@replica_mklhash, 'old')
    assert_true sw.change_mklhash?
    assert_equal %w(replica_2), sw.replica_nodelist
  end

  # Without a node, the replication stops.
  def test_change_mklhash_without_nodes
    sw = writer('replica_1' => nil)
    sw.instance_variable_set(:@replica_nodelist, %w(replica_1))
    sw.run_replication = true
    sw.change_mklhash?
    assert_false sw.run_replication
  end
end
