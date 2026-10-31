require 'roma/tools/text_client'

module Roma
  module Tools
    # Sends set, get and delete requests to nodes, and writes how many and
    # how fast every +interval+ seconds.
    class Bench
      # Counts the requests and their times.
      class Stats
        def initialize
          @lock = Mutex.new
          reset
        end

        def record(seconds)
          @lock.synchronize do
            @count += 1
            @max = seconds if seconds > @max
            @min = seconds if @min.nil? || seconds < @min
          end
        end

        # Measures the block.
        def measure
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ret = yield
          record(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
          ret
        end

        # Writes the report to +out+ every +interval+ seconds while the block
        # runs.
        def reporting(out, interval)
          reporter = Thread.new { loop { sleep interval; out.puts report(interval) } }
          yield
        ensure
          reporter&.kill
        end

        # Returns the line of the requests since the last report.
        def report(interval)
          @lock.synchronize do
            ave = @count.zero? ? 0 : interval / @count.to_f
            line = format('qps=%d max=%f min=%f ave=%f', @count / interval, @max, @min || 0, ave)
            reset
            line
          end
        end

        private

        def reset
          @count = 0
          @max = 0
          @min = nil
        end
      end

      MODES = %i(set get rand).freeze

      # +client+ makes a client for each thread. Requests that fail are
      # written to +out+.
      def initialize(node_ids, out: $stdout, interval: 10, client: -> { TextClient.new(node_ids) })
        @out = out
        @interval = interval
        @client = client
        @stats = Stats.new
      end

      # Runs +modes+ in order in each of +threads+: :set sets key_0 ... and
      # :get gets them, +num+ keys, and :rand sends random requests on +num+
      # keys until +duration+ seconds pass, or forever. A value is random
      # letters of +value_size+ if it is given.
      def run(modes, num: 10_000, threads: 1, value_size: nil, duration: nil)
        @stats.reporting(@out, @interval) do
          workers = Array.new(threads) do |i|
            @out.puts "Start thread #{i}"
            Thread.new do
              client = @client.call
              modes.each { |mode| send("run_#{mode}", client, num, value_size, duration) }
            ensure
              client&.close
            end
          end
          workers.each(&:join)
        end
      end

      private

      def value(i, value_size)
        value_size ? Array.new(value_size) { rand(97..122).chr }.join : "value_#{i}"
      end

      def run_set(client, num, value_size, _duration)
        @out.puts 'set_sequence'
        num.times do |i|
          request(client, "set k=#{i}") { |c| c.set("key_#{i}", value(i, value_size)) == 'STORED' }
          @out.puts "=====#{i * 100 / num}%(#{i}keys) has finished.=====" if i > 0 && i % 100_000 == 0
        end
      end

      # The values are checked unless they are random.
      def run_get(client, num, value_size, _duration)
        @out.puts 'get_sequence'
        num.times do |i|
          request(client, "get k=#{i}") do |c|
            got = c.get("key_#{i}")
            value_size ? !got.nil? : got == "value_#{i}"
          end
        end
      end

      def run_rand(client, num, value_size, duration)
        @out.puts 'random_request_sender'
        stop = duration && Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration
        until stop && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= stop
          i = rand(num)
          case rand(3)
          when 0 then request(client, "set k=#{i}") { |c| c.set(i.to_s, value(i, value_size)) == 'STORED' }
          when 1 then request(client, "get k=#{i}") { |c| c.get(i.to_s); true }
          else request(client, "del k=#{i}") { |c| %w(DELETED NOT_FOUND).include?(c.delete(i.to_s)) }
          end
        end
      end

      # The block returns false for a wrong reply.
      def request(client, label)
        ok = @stats.measure { yield client }
        @out.puts "#{label} failed" unless ok
      rescue Error => e
        @out.puts "#{label} #{e.message}"
      end
    end
  end
end
