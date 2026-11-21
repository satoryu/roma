module Roma
  class AsyncMessage
    # How many times an event that fails is tried again, and the seconds to
    # wait before each.
    RETRY_MAX = 10
    RETRY_WAIT = 0.1

    attr_accessor :event, :args, :callback

    def initialize(ev, ag = nil, &cb)
      @event = ev
      @args = ag
      @callback = cb
      @retry_count = 0
      @retry_max = RETRY_MAX
      @retry_wait = RETRY_WAIT
    end

    def retry?
      @retry_max > @retry_count
    end

    def incr_count
      @retry_count += 1
    end

    def wait
      sleep(@retry_wait)
    end
  end
end
