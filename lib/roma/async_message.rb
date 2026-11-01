module Roma
  class AsyncMessage
    attr_accessor :event
    attr_accessor :args
    attr_accessor :callback

    def initialize(ev, ag = nil, &cb)
      @event = ev
      @args = ag
      @callback = cb
      @retry_count = 0
      @retry_max = 10
      @retry_wait = 0.1
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
