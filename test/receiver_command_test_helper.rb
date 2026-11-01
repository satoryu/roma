require 'command_test_harness'

# Helpers of the unit tests of the command receivers and the plugins,
# which run the commands on a CommandTestHarness.
module ReceiverCommandTestHelper
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID

  def setup
    @conn = CommandTestHarness.new
  end

  def teardown
    @conn.close
    Roma::AsyncProcess.queue.clear
  end

  # The other nodes' replies come first.
  def replies(reply, other: 'STORED')
    "#{{ OTHER_NID => other, NID => reply }}\r\n"
  end

  def queued_events
    queue = Roma::AsyncProcess.queue
    Array.new(queue.size) { queue.pop.event }
  end
end
