require 'test_helper'

require 'eventmachine'

class EventMachineTest < Test::Unit::TestCase
  self.test_order = :defined
  LOOP_NUM = 5
  SLEEP_SEC = 0.2

  def test_context_switch
    EM.epoll
    Thread.new do
      LOOP_NUM.times do |i|
        100.times{ Thread.pass }
        sleep SLEEP_SEC
        #puts i
      end
      EM.stop_event_loop
    end
    s = Time.now
    EventMachine::run
    e = Time.now
    # A thread blocked by the event loop would make it take far longer.
    assert((e - s) < LOOP_NUM * SLEEP_SEC + 1)
  end
end
