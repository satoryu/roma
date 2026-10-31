require 'test_helper'
require 'eventmachine'
require 'command_test_harness'

# Unit tests for the system commands that stop romad or restart its event
# loop: balse, shutdown, shutdown_self and restart, with their relayed
# versions, and quit.
class SysCommandStopTest < Test::Unit::TestCase
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID

  def setup
    @conn = CommandTestHarness.new
    @conn.rttable.enabled_failover = true
  end

  def teardown
    @conn.close
  end

  def replies(reply)
    "#{{ OTHER_NID => reply, NID => reply }}\r\n"
  end

  def assert_stopped
    assert_equal :after_writing, @conn.closed
    assert_true @conn.stop_event_loop?
    # Failover is off, so the other nodes don't take this node as failed.
    assert_false @conn.rttable.enabled_failover
  end

  def assert_not_stopped
    assert_equal :after_writing, @conn.closed
    assert_false @conn.stop_event_loop?
    assert_true @conn.rttable.enabled_failover
    assert_equal [], @conn.broadcasts
  end

  # Runs +line+ in a running EventMachine reactor, as romad does, and
  # returns the reply after the reactor has stopped.
  def request_in_reactor(line)
    reply = nil
    timed_out = false
    EM.run do
      reply = @conn.request(line)
      # Stops the test if the command doesn't stop the reactor.
      EM.add_timer(1) do
        timed_out = true
        EM.stop
      end
    end
    assert_false timed_out, "#{line} didn't stop the reactor"
    reply
  end

  data('balse' => ['balse', "Are you sure?(yes/no)\r\n"],
       'shutdown' => ['shutdown', "*** ARE YOU REALLY SURE TO SHUTDOWN? *** (yes/no)\r\n"])
  def test_stop_cluster(data)
    command, question = data
    @conn.relay_reply = 'BYE'
    assert_equal question + replies('BYE'), @conn.request(command, 'yes')
    assert_equal ["r#{command}\r\n"], @conn.broadcasts
    assert_stopped
  end

  data('balse' => ['balse', "Are you sure?(yes/no)\r\n"],
       'shutdown' => ['shutdown', "*** ARE YOU REALLY SURE TO SHUTDOWN? *** (yes/no)\r\n"])
  def test_stop_cluster_with_reason(data)
    command, question = data
    @conn.relay_reply = 'BYE'
    assert_equal question + replies('BYE'), @conn.request("#{command} maintenance", 'yes')
    # The reason isn't relayed.
    assert_equal ["r#{command}\r\n"], @conn.broadcasts
    assert_stopped
  end

  data('balse, no' => ['balse', 'no'],
       'balse, no answer' => ['balse', nil],
       'shutdown, no' => ['shutdown', 'no'],
       'shutdown, YES' => ['shutdown', 'YES'])
  def test_stop_cluster_not_confirmed(data)
    command, answer = data
    assert_equal 1, @conn.request(command, answer).lines.size
    assert_not_stopped
  end

  data('rbalse' => 'rbalse', 'rshutdown' => 'rshutdown',
       'rbalse with reason' => 'rbalse maintenance', 'rshutdown with reason' => 'rshutdown maintenance')
  def test_relayed_stop(line)
    assert_equal "BYE\r\n", @conn.request(line)
    assert_equal [], @conn.broadcasts
    assert_stopped
  end

  SHUTDOWN_SELF_QUESTION =
    "\r\n=================================================================\r\n" \
    "CAUTION!!: \r\n\tThis command kill the instance!\r\n\tThere is some possibility of occuring redundancy down!\r\n" \
    "=================================================================\r\n" \
    "\r\nAre you sure to shutdown this instance?(yes/no)\r\n"

  def test_shutdown_self
    assert_equal SHUTDOWN_SELF_QUESTION + "BYE\r\n", @conn.request('shutdown_self', 'yes')
    # Only this node stops.
    assert_equal [], @conn.broadcasts
    assert_stopped
  end

  def test_shutdown_self_not_confirmed
    assert_equal SHUTDOWN_SELF_QUESTION, @conn.request('shutdown_self', 'no')
    assert_not_stopped
  end

  def test_shutdown_self_with_argument
    assert_equal "ERROR: shutdown_instance has irregular argument.\r\n", @conn.request('shutdown_self now', 'yes')
    assert_nil @conn.closed
    assert_false @conn.stop_event_loop?
  end

  def test_quit
    assert_equal '', @conn.request('quit')
    assert_equal :now, @conn.closed
    assert_false @conn.stop_event_loop?
  end

  def test_restart
    @conn.relay_reply = 'RESTARTED'
    assert_equal replies('RESTARTED'), request_in_reactor('restart')
    assert_equal ["rrestart\r\n"], @conn.broadcasts
    # romad runs the event loop again once it stops.
    assert_true @conn.romad.eventloop
    assert_false @conn.rttable.enabled_failover
  end

  def test_rrestart
    assert_equal "RESTARTED\r\n", request_in_reactor('rrestart')
    assert_equal [], @conn.broadcasts
    assert_true @conn.romad.eventloop
    assert_false @conn.rttable.enabled_failover
  end

  # Restarting doesn't close the connection itself; stopping the reactor
  # does.
  def test_restart_keeps_the_connection
    request_in_reactor('rrestart')
    assert_nil @conn.closed
    assert_false @conn.stop_event_loop?
  end
end
