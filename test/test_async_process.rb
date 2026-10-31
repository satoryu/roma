require 'test_helper'
require 'async_process_harness'
require 'fake_node'

# Unit tests for the background processes of romad (Roma::AsyncProcess).
module AsyncProcessTestHelper
  NID = AsyncProcessHarness::NID
  OTHER_NID = AsyncProcessHarness::OTHER_NID

  def teardown
    @h&.close
    @node&.close
    Roma::Messaging::ConPool.instance.close_all
  end

  # Waits for a process started in a thread.
  def wait_until(what, timeout: 5)
    deadline = Time.now + timeout
    until yield
      flunk("timed out waiting for #{what}") if Time.now > deadline
      Kernel.sleep 0.01
    end
  end

  def digest(key)
    Digest::SHA1.hexdigest(key).hex % @h.rttable.hbits
  end
end

class AsyncMessageTest < Test::Unit::TestCase
  def test_retry
    msg = Roma::AsyncMessage.new('redundant', [1, 2])
    assert_equal ['redundant', [1, 2]], [msg.event, msg.args]
    10.times do
      assert_true msg.retry?
      msg.incr_count
    end
    assert_false msg.retry?
  end
end

class AsyncProcessLoopTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  # Handles the test events: ok succeeds, ng fails and error raises.
  class Harness < AsyncProcessHarness
    attr_reader :handled

    def initialize
      super
      @handled = Queue.new
    end

    private

    def asyncev_ok(args)
      @handled << args
      true
    end

    def asyncev_ng(args)
      @handled << args
      false
    end

    def asyncev_error(_args)
      raise 'error in the event'
    end
  end

  def setup
    @h = Harness.new
  end

  def teardown
    @h.call(:stop_async_process) if @h.instance_variable_get(:@async_thread)
    Roma::AsyncProcess.queue.clear
    Roma::AsyncProcess.queue_latency.clear
    super
  end

  data('async_queue' => :queue, 'latency queue' => :queue_latency)
  def test_runs_the_event_and_calls_back(queue)
    @h.start_async_process
    results = Queue.new
    Roma::AsyncProcess.send(queue).push(Roma::AsyncMessage.new('ok', 'a') { |msg, ok| results << [msg.args, ok] })
    assert_equal ['a', true], results.pop
  end

  data('async_queue' => :queue, 'latency queue' => :queue_latency)
  def test_retries_a_failed_event(queue)
    @h.start_async_process
    results = Queue.new
    msg = Roma::AsyncMessage.new('ng', 'a') { |m, ok| results << [m.args, ok] }
    msg.instance_variable_set(:@retry_max, 2)
    msg.instance_variable_set(:@retry_wait, 0)
    Roma::AsyncProcess.send(queue).push(msg)
    assert_equal ['a', false], results.pop
    # Run once, then retried twice.
    assert_equal 3, @h.handled.size
  end

  def test_keeps_running_after_an_error
    @h.start_async_process
    Roma::AsyncProcess.queue.push(Roma::AsyncMessage.new('error'))
    results = Queue.new
    Roma::AsyncProcess.queue.push(Roma::AsyncMessage.new('ok', 'b') { |msg, ok| results << [msg.args, ok] })
    assert_equal ['b', true], results.pop
  end
end

class AsyncProcessEventTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  # Records the processes instead of running them.
  class Harness < AsyncProcessHarness
    attr_reader :calls

    def initialize(**opts)
      super
      @calls = Queue.new
    end

    private

    %i(join_process balance_process acquired_recover_process release_process).each do |name|
      define_method(name) { @calls << name }
    end

    def sync_a_vnode(*args)
      @calls << [:sync_a_vnode, *args]
    end
  end

  def setup
    @h = Harness.new
  end

  def test_broadcast_cmd
    assert_true @h.call(:asyncev_broadcast_cmd, ['stat', nil, 5])
    wait_until('the broadcast') { @h.broadcasts == ["stat\r\n"] }
  end

  data('join' => [:asyncev_start_join_process, :join_process, :run_join],
       'balance' => [:asyncev_start_balance_process, :balance_process, :run_balance],
       'recover' => [:asyncev_start_recover_process, :acquired_recover_process, :run_recover])
  def test_start_process(data)
    event, process, flag = data
    @h.stats.join_ap = OTHER_NID if flag == :run_join
    @h.call(event, nil)
    assert_equal process, @h.calls.pop
    wait_until("#{flag} to be cleared") { !@h.stats.send(flag) }
    assert_nil @h.stats.join_ap
  end

  # Only one of join, balance and recover runs at a time.
  data do
    events = { 'join' => :asyncev_start_join_process, 'balance' => :asyncev_start_balance_process,
               'recover' => :asyncev_start_recover_process }
    events.keys.product(%i(run_join run_balance run_recover)).to_h do |name, flag|
      ["#{name} while #{flag}", [events[name], flag]]
    end
  end
  def test_start_process_while_another_runs(data)
    event, flag = data
    @h.stats.send("#{flag}=", true)
    ret = @h.call(event, nil)
    # recover asks to be retried if recover is running.
    assert_equal(!(event == :asyncev_start_recover_process && flag == :run_recover), ret)
    assert_true @h.calls.empty?
  end

  def test_start_release_process
    @h.call(:asyncev_start_release_process, nil)
    assert_equal :release_process, @h.calls.pop
    wait_until('release to finish') { !@h.stats.run_release }
    assert_false @h.stats.run_iterate_storage
    # It stays on: this node no longer accepts vnodes.
    assert_true @h.stats.spushv_protection
  end

  def test_start_release_process_while_iterating_storage
    @h.stats.run_iterate_storage = true
    @h.call(:asyncev_start_release_process, nil)
    assert_false @h.stats.run_release
    assert_true @h.calls.empty?
  end

  def test_reqpushv
    @h.call(:asyncev_reqpushv, ['536870912', OTHER_NID, 'true'])
    assert_equal [:sync_a_vnode, 536_870_912, OTHER_NID, true], @h.calls.pop
    wait_until('the storage iteration to finish') { !@h.stats.run_iterate_storage }
  end

  def test_reqpushv_while_iterating_storage
    @h.stats.run_iterate_storage = true
    @h.call(:asyncev_reqpushv, ['0', OTHER_NID, 'false'])
    assert_true @h.calls.empty?
  end

  def test_start_auto_recover_process
    @h.rttable.lost_action = :auto_assign
    @h.rttable.auto_recover_time = 0.1
    @h.call(:asyncev_start_auto_recover_process, nil)
    assert_equal :acquired_recover_process, @h.calls.pop
    wait_until('auto recover to finish') { @h.rttable.auto_recover_status == 'waiting' }
    assert_false @h.stats.run_recover
  end

  def test_start_auto_recover_process_with_no_action
    @h.rttable.auto_recover_time = 0.1
    @h.call(:asyncev_start_auto_recover_process, nil)
    Kernel.sleep 0.3
    assert_true @h.calls.empty?
    assert_equal 'preparing', @h.rttable.auto_recover_status
  end

  data('recover running' => [:run_recover, false], 'balance running' => [:run_balance, true])
  def test_start_auto_recover_process_while_another_runs(data)
    flag, ret = data
    @h.stats.send("#{flag}=", true)
    assert_equal ret, @h.call(:asyncev_start_auto_recover_process, nil)
    assert_equal 'waiting', @h.rttable.auto_recover_status
  end

  data('redundant' => [:asyncev_redundant, "rset key\eroma 1 2 0 5\r\nvalue\r\n"],
       'zredundant' => [:asyncev_zredundant, "rzset key\eroma 1 2 0 5\r\nvalue\r\n"])
  def test_redundant(data)
    event, cmd = data
    assert_true @h.call(event, [OTHER_NID, 'roma', 'key', 1, 2, 0, 'value'])
    assert_equal [[OTHER_NID, cmd]], @h.sent
  end

  data('redundant' => :asyncev_redundant, 'zredundant' => :asyncev_zredundant)
  def test_redundant_to_unknown_node(event)
    # Not retried.
    assert_true @h.call(event, ['localhost_99999', 'roma', 'key', 1, 2, 0, 'value'])
    assert_equal [], @h.sent
  end

  data('no reply' => nil, 'error' => "ERROR\r\n")
  def test_redundant_failed(reply)
    @h.send_cmd_reply = reply
    # Retried.
    assert_false @h.call(:asyncev_redundant, [OTHER_NID, 'roma', 'key', 1, 2, 0, 'value'])
  end

  def test_zredundant_failed
    @h.send_cmd_reply = nil
    # Retried.
    assert_false @h.call(:asyncev_zredundant, [OTHER_NID, 'roma', 'key', 1, 2, 0, 'value'])
  end

  def test_rdelete
    assert_true @h.call(:asyncev_rdelete, [OTHER_NID, 'roma', 'key', 3])
    assert_equal [[OTHER_NID, "rdelete key\eroma 3\r\n"]], @h.sent

    assert_true @h.call(:asyncev_rdelete, ['localhost_99999', 'roma', 'key', 3])
    @h.send_cmd_reply = nil
    assert_false @h.call(:asyncev_rdelete, [OTHER_NID, 'roma', 'key', 3])
  end
end

# join, balance and recover ask other nodes to push vnodes to this node.
class AsyncProcessAcquireTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  # Pushing a vnode puts this node in it, at once.
  class Harness < AsyncProcessHarness
    attr_reader :requests
    attr_accessor :push_reply
    # Makes this node primary of every vnode pushed, instead of as asked.
    attr_accessor :always_primary

    def initialize(**opts)
      super
      @requests = []
      @push_reply = true
    end

    private

    def req_push_a_vnode(vn, src_nid, is_primary)
      @requests << [vn, src_nid, is_primary]
      return @push_reply unless @push_reply == true
      nids = @rttable.search_nodes(vn) - [@stats.ap_str]
      is_primary || @always_primary ? nids.unshift(@stats.ap_str) : nids.push(@stats.ap_str)
      @rttable.set_route(vn, @rttable.search_nodes_with_clk(vn)[0], nids)
      true
    end
  end

  def test_join_process
    @h = Harness.new(nodes: %w(hosta_1 hostb_1))
    @h.always_primary = true
    @h.call(:join_process)
    # Takes vnodes until it is primary of its share: 8 vnodes / 3 nodes.
    assert_equal :even, @h.rttable.vnode_balance(NID)
    assert_equal 2, @h.requests.size
    @h.requests.each { |vn, src, _| assert_include @h.rttable.search_nodes(vn), NID unless src == NID }
  end

  # It asks for at most as many vnodes as there are.
  def test_join_process_never_primary
    @h = Harness.new(nodes: %w(hosta_1 hostb_1))
    def @h.req_push_a_vnode(vn, src_nid, _is_primary)
      super(vn, src_nid, false)
    end
    @h.call(:join_process)
    assert_equal :less, @h.rttable.vnode_balance(NID)
    assert_equal 8, @h.requests.size
  end

  def test_join_process_rejected
    @h = Harness.new(nodes: %w(hosta_1 hostb_1))
    @h.push_reply = :rejected
    @h.instance_variable_set(:@do_join_process, true)
    thread = Thread.new { @h.call(:join_process) }
    wait_until('requests') { @h.requests.size >= 3 }
    # Stopping it ends the loop.
    @h.instance_variable_set(:@do_join_process, false)
    thread.join
    assert_include @h.slept, 5
    assert_equal :less, @h.rttable.vnode_balance(NID)
  end

  def test_join_process_without_vnodes_to_take
    # This node is in every vnode.
    @h = Harness.new(nodes: [NID, 'hosta_1'], vnode_nodes: ['hosta_1', NID])
    assert_false @h.call(:join_process)
    assert_equal [], @h.requests
  end

  def test_balance_process
    @h = Harness.new(nodes: [NID, 'hosta_1', 'hostb_1'], vnode_nodes: %w(hosta_1 hostb_1))
    @h.stats.enabled_repetition_host_in_routing = true
    @h.always_primary = true
    @h.call(:balance_process)
    # Takes vnodes until it is primary of its share: 8 vnodes / 3 nodes.
    assert_equal :even, @h.rttable.vnode_balance(NID)
    assert_equal 2, @h.requests.size
  end

  def test_acquired_recover_process
    # Every vnode has one node, though it should have two.
    @h = Harness.new(nodes: [NID, 'hosta_1'], vnode_nodes: ['hosta_1'])
    @h.stats.enabled_repetition_host_in_routing = true
    @h.call(:acquired_recover_process)
    @h.rttable.each_vnode { |vn, nids| assert_equal 2, nids.size, "vnode #{vn}" }
    assert_equal 8, @h.requests.size
    assert_include @h.slept, 1
  end

  def test_acquired_recover_process_stops_at_an_error
    @h = Harness.new(nodes: [NID, 'hosta_1'], vnode_nodes: ['hosta_1'])
    @h.stats.enabled_repetition_host_in_routing = true
    @h.push_reply = false
    @h.call(:acquired_recover_process)
    assert_equal 1, @h.requests.size
  end
end

# Pushing vnodes to other nodes, through a FakeNode.
class AsyncProcessPushTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  def setup
    @node = FakeNode.new
    @h = AsyncProcessHarness.new(nodes: [NID, OTHER_NID, @node.nid], vnode_nodes: [NID, OTHER_NID])
    @vn = @h.store('key1', 'value1')
  end

  def test_push_a_vnode_stream
    assert_equal 'STORED', @h.call(:push_a_vnode_stream, 'roma', @vn, @node.nid)
    assert_equal ["spushv roma #{@vn}"], @node.commands
    assert_equal ['key1'], @node.dat[@vn].keys
    assert_equal 'value1', @node.dat[@vn]['key1'].unpack('NNNNa*').last
  end

  def test_push_a_vnode_stream_refused
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    assert_equal 'SERVER_ERROR busy', @h.call(:push_a_vnode_stream, 'roma', @vn, @node.nid)
  end

  def test_push_a_vnode_stream_while_the_storage_is_busy
    @h.storage.set_db_stat(@h.storage.hdiv[@vn], :safecopy_flushing)
    assert_equal 'CANCELED', @h.call(:push_a_vnode_stream, 'roma', @vn, @node.nid)
  end

  def test_push_a_vnode_stream_to_a_node_that_is_down
    # The error message is returned.
    assert_not_equal 'STORED', @h.call(:push_a_vnode_stream, 'roma', @vn, 'localhost_1')
  end

  def test_sync_a_vnode_adds_the_node
    assert_true @h.call(:sync_a_vnode, @vn, @node.nid, false)
    assert_equal ['key1'], @node.dat[@vn].keys
    # Redundancy is 2, so the new node replaces the last one.
    assert_equal [NID, @node.nid], @h.rttable.search_nodes(@vn)
    clk = @h.rttable.search_nodes_with_clk(@vn)[0]
    assert_equal ["setroute #{@vn} #{clk - 1} #{NID} #{@node.nid}\r\n"], @h.broadcasts
  end

  def test_sync_a_vnode_as_primary
    assert_true @h.call(:sync_a_vnode, @vn, @node.nid, true)
    assert_equal [@node.nid, NID], @h.rttable.search_nodes(@vn)
  end

  def test_sync_a_vnode_already_in_the_vnode
    # The data is pushed again; the routing doesn't change.
    @h2 = AsyncProcessHarness.new(nodes: [NID, @node.nid], vnode_nodes: [NID, @node.nid])
    vn = @h2.store('key1', 'value1')
    assert_true @h2.call(:sync_a_vnode, vn, @node.nid, false)
    assert_equal ['key1'], @node.dat[vn].keys
    assert_equal [NID, @node.nid], @h2.rttable.search_nodes(vn)
    assert_equal [], @h2.broadcasts
  ensure
    @h2&.close
  end

  def test_sync_a_vnode_failed
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    assert_false @h.call(:sync_a_vnode, @vn, @node.nid, false)
    assert_equal [NID, OTHER_NID], @h.rttable.search_nodes(@vn)
    # The transaction was rolled back.
    assert_true @h.rttable.transaction(@vn, [NID])
  end

  def test_sync_a_vnode_for_release
    assert_true @h.call(:sync_a_vnode_for_release, @vn, @node.nid, [@node.nid, OTHER_NID])
    assert_equal ['key1'], @node.dat[@vn].keys
    assert_equal [@node.nid, OTHER_NID], @h.rttable.search_nodes(@vn)
    assert_match(/\Asetroute #{@vn} \d+ #{@node.nid} #{OTHER_NID}\r\n\z/, @h.broadcasts.first)
  end

  data('server error' => ["SERVER_ERROR busy\r\n", :abort], 'other error' => ["NOT_READY\r\n", false])
  def test_sync_a_vnode_for_release_failed(data)
    reply, ret = data
    @node.replies['spushv'] = reply
    assert_equal ret, @h.call(:sync_a_vnode_for_release, @vn, @node.nid, [@node.nid, OTHER_NID])
    assert_equal [NID, OTHER_NID], @h.rttable.search_nodes(@vn)
  end

  def test_sync_a_vnode_for_release_to_a_node_in_the_vnode
    assert_true @h.call(:sync_a_vnode_for_release, @vn, OTHER_NID, [OTHER_NID])
    assert_equal [], @node.commands
  end

  def test_req_push_a_vnode
    # This node is in the vnode already, so it doesn't wait for the push.
    assert_true @h.call(:req_push_a_vnode, @vn, @node.nid, true)
    assert_equal ["reqpushv #{@vn} #{NID} true"], @node.commands
  end

  data('rejected' => "REJECTED\r\n", 'error' => "ERROR\r\n")
  def test_req_push_a_vnode_rejected(reply)
    @node.replies['reqpushv'] = reply
    assert_equal :rejected, @h.call(:req_push_a_vnode, @vn, @node.nid, false)
  end

  def test_req_push_a_vnode_time_out
    @h.stats.reqpushv_timeout_count = 3
    other = @h.rttable.v_idx.keys.find { |vn| vn != @vn }
    @h.rttable.set_route(other, 0, [OTHER_NID])
    assert_equal :timeout, @h.call(:req_push_a_vnode, other, @node.nid, false)
    assert_equal [0.1] * 3, @h.slept
  end

  def test_req_push_a_vnode_to_a_node_that_is_down
    assert_false @h.call(:req_push_a_vnode, @vn, 'localhost_1', false)
    assert_equal 1, @h.rttable.fail_cnt['localhost_1']
  end

  def test_replicate_existing_data_process
    replica = Struct.new(:v_idx).new(@h.rttable.v_idx.keys.to_h { |vn| [vn, [@node.nid]] })
    saved = defined?($roma) ? $roma : nil
    $roma = Struct.new(:cr_writer).new(Struct.new(:run_existing_data_replication).new(true))
    @h.call(:replicate_existing_data_process, [replica])
    assert_equal @h.rttable.v_idx.keys.sort, @node.dat.keys.sort
    assert_equal ['key1'], @node.dat[@vn].keys
  ensure
    $roma = saved
  end
end

class AsyncProcessReleaseTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  # Moving a vnode replaces this node at once.
  class Harness < AsyncProcessHarness
    attr_reader :moves
    attr_accessor :move_reply

    def initialize(**opts)
      super
      @moves = []
      @move_reply = true
    end

    private

    def sync_a_vnode_for_release(vn, to_nid, new_nids)
      @moves << [vn, to_nid]
      return @move_reply unless @move_reply == true
      @rttable.set_route(vn, @rttable.search_nodes_with_clk(vn)[0], new_nids)
      true
    end
  end

  def test_release_process
    @h = Harness.new(nodes: [NID, 'hosta_1', 'hostb_1'], vnode_nodes: [NID, 'hosta_1'])
    @h.stats.enabled_repetition_host_in_routing = true
    @h.call(:release_process)
    assert_false @h.rttable.has_node?(NID)
    assert_equal 8, @h.moves.size
    @h.moves.each { |_vn, to_nid| assert_equal 'hostb_1', to_nid }
  end

  def test_release_process_without_enough_nodes
    @h = Harness.new(nodes: [NID, 'hosta_1'], vnode_nodes: [NID, 'hosta_1'])
    @h.stats.enabled_repetition_host_in_routing = true
    @h.call(:release_process)
    assert_equal [], @h.moves
  end

  def test_release_process_aborted
    @h = Harness.new(nodes: [NID, 'hosta_1', 'hostb_1'], vnode_nodes: [NID, 'hosta_1'])
    @h.stats.enabled_repetition_host_in_routing = true
    @h.move_reply = :abort
    # It would keep trying the vnode if it didn't stop.
    thread = Thread.new { @h.call(:release_process) }
    assert_not_nil thread.join(5), 'release_process did not stop'
    assert_equal 1, @h.moves.size
  ensure
    thread&.kill
  end
end

class AsyncProcessEditNodesTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  def setup
    @h = AsyncProcessHarness.new
  end

  data('secondary' => [%w(hosta_1 hostb_1), 'hostc_1', false, %w(hosta_1 hostc_1)],
       'primary' => [%w(hosta_1 hostb_1), 'hostc_1', true, %w(hostc_1 hosta_1)],
       'same host as the new node' => [%w(hosta_1 hostc_2), 'hostc_1', false, %w(hosta_1 hostc_1)],
       'short vnode' => [%w(hosta_1), 'hostc_1', false, %w(hosta_1 hostc_1)],
       'already in the vnode' => [%w(hostc_1 hosta_1), 'hostc_1', true, %w(hostc_1 hosta_1)])
  def test_edit_nodes(data)
    nodes, new_nid, is_primary, expected = data
    assert_equal expected, @h.call(:edit_nodes, nodes.dup, new_nid, is_primary)
  end

  def test_edit_nodes_without_redundancy
    @h.rttable.instance_variable_set(:@rn, 1)
    assert_equal ['hostc_1'], @h.call(:edit_nodes, %w(hosta_1), 'hostc_1', false)
  end
end

class AsyncProcessStorageTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  def setup
    @h = AsyncProcessHarness.new(vnode_nodes: [NID, OTHER_NID])
    # Long enough since the last clean up.
    @h.stats.last_clean_up = Time.at(0)
  end

  def test_storage_clean_up_process
    vn = @h.store('expired', 'v', expt: Time.now.to_i - 10)
    @h.store('alive', 'v')
    @h.call(:storage_clean_up_process)
    assert_nil @h.storage.get(vn, 'expired', digest('expired'))
    alive_vn = @h.store('alive', 'v')
    assert_equal 'v', @h.storage.get(alive_vn, 'alive', digest('alive'))
    # The other node of the vnode is told to delete it too.
    assert_equal [[OTHER_NID, "out expired\eroma #{vn}\r\n"]], @h.sent
    assert_equal 1, @h.stats.out_count
  end

  def test_storage_clean_up_process_soon_after_the_last
    @h.store('expired', 'v', expt: Time.now.to_i - 10)
    @h.stats.last_clean_up = Time.now
    @h.call(:storage_clean_up_process)
    assert_equal [], @h.sent
    assert_equal 0, @h.stats.out_count
  end

  def test_storage_clean_up_process_skips_a_vnode_being_received
    vn = @h.store('expired', 'v', expt: Time.now.to_i - 10)
    @h.stats.run_receive_a_vnode["roma_#{vn}"] = true
    @h.call(:storage_clean_up_process)
    assert_equal [], @h.sent
    assert_equal 0, @h.stats.out_count
  end

  data('old logs' => [Time.now - 600, false, []],
       'new logs' => [Time.now, false, 2],
       'gathering logs' => [Time.now - 600, true, 2])
  def test_storage_clean_up_process_clears_gathered_logs(data)
    gathered, gathering, expected = data
    @h.rttable.logs = [gathered, 'log line']
    @h.stats.gui_run_gather_logs = gathering
    @h.call(:storage_clean_up_process)
    if expected == []
      assert_equal [], @h.rttable.logs
    else
      assert_equal expected, @h.rttable.logs.size
    end
  end

  def test_start_storage_clean_up_process
    @h.stats.last_clean_up = nil
    @h.call(:asyncev_start_storage_clean_up_process, nil)
    wait_until('clean up to finish') { !@h.stats.run_storage_clean_up }
    assert_not_nil @h.stats.last_clean_up

    @h.stats.run_storage_clean_up = true
    @h.stats.last_clean_up = nil
    @h.call(:asyncev_start_storage_clean_up_process, nil)
    assert_nil @h.stats.last_clean_up
  end

  def test_storage_flush_process
    assert_true @h.call(:asyncev_start_storage_flush_process, ['roma', 0])
    assert_equal :normal, @h.storage.dbs[0]

    @h.storage.set_db_stat(0, :safecopy_flushing)
    assert_true @h.call(:asyncev_start_storage_flush_process, ['roma', 0])
    wait_until('the flush') { @h.storage.dbs[0] == :safecopy_flushed }
  end

  def test_storage_cachecleaning_process
    dn = 0
    vn = @h.storage.hdiv.key(dn)
    assert_true @h.call(:asyncev_start_storage_cachecleaning_process, ['roma', dn])
    assert_equal :normal, @h.storage.dbs[dn]

    @h.storage.set_db_stat(dn, :safecopy_flushing)
    # Written to the cache while the storage is flushed.
    @h.storage.set(vn, 'cached', digest('cached'), 0x7fffffff, 'v')
    @h.storage.set_db_stat(dn, :safecopy_flushed)
    @h.storage.set_db_stat(dn, :cachecleaning)
    assert_true @h.call(:asyncev_start_storage_cachecleaning_process, ['roma', dn])
    wait_until('cache cleaning') { @h.storage.dbs[dn] == :normal }
    assert_equal 'v', @h.storage.get(vn, 'cached', digest('cached'))
    assert_equal [], @h.storage.get_keys_in_cache(dn)
  end

  def test_calc_latency_average
    @h.stats.latency_check_time_count = 60
    [0.3, 0.1, 0.2].each { |latency| assert_true @h.call(:asyncev_calc_latency_average, [latency, 'get']) }
    data = @h.stats.latency_data['get']
    assert_equal [0.3, 0.1, 0.2], data['latency']
    assert_equal 0.3, data['latency_max']['current']
    assert_equal 0.1, data['latency_min']['current']

    # Keeps the last 10.
    11.times { |i| @h.call(:asyncev_calc_latency_average, [i, 'get']) }
    assert_equal (1..10).to_a, data['latency']

    # After latency_check_time_count seconds, starts over.
    data['time'] -= 61
    @h.call(:asyncev_calc_latency_average, [0.5, 'get'])
    assert_equal [], data['latency']
    assert_equal [2, 3, 4, 5, 6, 7, 8, 9, 10, 0.5], data['latency_past']
    assert_equal 10, data['latency_max']['past']
    assert_equal 0, data['latency_max']['current']
    assert_equal 99_999, data['latency_min']['current']
  end
end

# Reads the routing logs and romad's log, in Roma::Config::RTTABLE_PATH and
# LOG_PATH, named after this node.
class AsyncProcessLogTest < Test::Unit::TestCase
  include AsyncProcessTestHelper

  BASE = Time.local(2026, 1, 2, 3, 0, 0)

  def setup
    @h = AsyncProcessHarness.new
    @h.stats.address = 'asyncprocesstest'
    @h.stats.port = Process.pid.to_s
    @files = []
  end

  def teardown
    @files.each { |f| FileUtils.rm_f(f) }
    super
  end

  def write(path, text)
    @files << path
    File.write(path, text)
  end

  def test_get_routing_event
    write("#{Roma::Config::RTTABLE_PATH}/#{@h.stats.ap_str}.route.1",
          "2026-01-02T03:00:00.1 join hosta_1\n" \
          "2026-01-02T03:00:01.1 setroute 0 1 hosta_1\n" \
          "2026-01-02T03:00:02.1 leave hosta_1\n")
    @h.call(:get_routing_event)
    assert_equal ['2026-01-02T03:00:00.1 join hosta_1', '2026-01-02T03:00:02.1 leave hosta_1'],
                 @h.rttable.event

    @h.rttable.event.clear
    @h.rttable.event_limit_line = 1
    @h.call(:get_routing_event)
    assert_equal ['2026-01-02T03:00:02.1 leave hosta_1'], @h.rttable.event
  end

  # One line a second for 300 seconds after BASE, in Logger's format.
  def write_log
    lines = (0...300).map do |i|
      "I, [#{(BASE + i).strftime('%Y-%m-%dT%H:%M:%S')}.000000 ##{i}]  INFO -- : message #{i}\n"
    end
    write("#{Roma::Config::LOG_PATH}/#{@h.stats.ap_str}.log", lines.join)
    lines.map(&:chomp)
  end

  def gathered_logs
    assert_kind_of Time, @h.rttable.logs.first
    @h.rttable.logs[1..]
  end

  def test_get_logs
    lines = write_log
    @h.stats.gui_run_gather_logs = true
    @h.call(:get_logs, ['2026-01-02T03:01:00', '2026-01-02T03:02:00'])
    assert_equal lines[60...120], gathered_logs
    assert_false @h.stats.gui_run_gather_logs
  end

  def test_get_logs_from_before_the_log_to_the_end
    lines = write_log
    @h.call(:get_logs, ['2026-01-01T00:00:00', 'current'])
    assert_equal lines, gathered_logs
  end

  def test_get_logs_to_after_the_log
    lines = write_log
    @h.call(:get_logs, ['2026-01-02T03:04:00', '2026-01-03T00:00:00'])
    assert_equal lines[240..], gathered_logs
  end

  data('start after the log' => ['2026-01-03T00:00:00', 'current'],
       'end before the log' => ['2026-01-02T03:00:10', '2026-01-01T00:00:00'])
  def test_get_logs_out_of_range(range)
    write_log
    @h.call(:get_logs, range)
    assert_equal [], @h.rttable.logs
  end

  def test_get_logs_without_a_log
    @h.call(:get_logs, ['2026-01-02T03:01:00', 'current'])
    assert_equal [], @h.rttable.logs
  end

  def test_start_get_logs
    write_log
    @h.stats.gui_run_gather_logs = true
    @h.call(:asyncev_start_get_logs, ['2026-01-02T03:01:00', '2026-01-02T03:01:01'])
    wait_until('gathering logs') { !@h.stats.gui_run_gather_logs }
    assert_equal 1, gathered_logs.size
  end
end
