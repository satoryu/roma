require 'command_test_harness'

# Helpers of the unit tests of the command receivers and the plugins,
# which run the commands on a CommandTestHarness.
module ReceiverCommandTestHelper
  NODE_ID = CommandTestHarness::NODE_ID
  OTHER_NODE_ID = CommandTestHarness::OTHER_NODE_ID

  def setup
    @conn = CommandTestHarness.new
  end

  def teardown
    @conn.close
    Roma::AsyncEvent.queue.clear
  end

  # The other nodes' replies come first.
  def replies(reply, other: 'STORED')
    "#{{ OTHER_NODE_ID => other, NODE_ID => reply }}\r\n"
  end

  def queued_events
    queue = Roma::AsyncEvent.queue
    Array.new(queue.size) { queue.pop.event }
  end
end
