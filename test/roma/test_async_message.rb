require 'test_helper'
require 'roma/async_message'

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
