require 'roma/tools/admin_client'
require 'roma/tools/error'
require 'roma/tools/text_client'

module Roma
  module Tools
    # Switches each divided file of a node to safecopy and back to normal
    # while keys are set, and checks the keys.
    class SafecopyTest
      # Sets the keys to the number of the round, round after round in a
      # thread, until it is stopped.
      class Writer
        attr_reader :prefix

        def initialize(client, prefix, keys)
          @client = client
          @prefix = prefix
          @keys = keys
          @round = 0
          @done = -1 # the last key set in the round
          @stop = false
          @rounds = Queue.new
        end

        def start
          @thread = Thread.new do
            until @stop
              @round += 1
              @done = -1
              @keys.times do |i|
                break unless set(i)
                @done = i
              end
              @rounds << @round unless @stop
            end
          end
          self
        end

        # Waits until a round is done. Raises the error of the thread if it
        # died.
        def wait_round
          until (round = @rounds.pop(timeout: 1))
            @thread.join unless @thread.alive?
          end
          round
        end

        # Stops after the key that is being set.
        def stop
          @stop = true
          @thread.join
          @client.close
        end

        # The value that key +i+ should have.
        def expected(i)
          (i <= @done ? @round : @round - 1).to_s
        end

        private

        # Tries again until it is stored, since the node may be busy, and
        # returns false if it is stopped before that.
        def set(i)
          loop do
            return false if @stop
            begin
              return true if @client.set("#{@prefix}_#{i}", @round.to_s) == 'STORED'
            rescue Error
              nil
            end
            sleep 0.1
          end
        end
      end

      # +client+ makes a client for the keys, and +admin+ sends the commands.
      # The status is asked every +wait+ seconds.
      def initialize(node_id, out: $stdout, client: -> { TextClient.new([node_id]) }, admin: AdminClient.new,
                     wait: 5, hash_name: 'roma')
        @node_id = node_id
        @out = out
        @client = client
        @admin = admin
        @wait = wait
        @hash_name = hash_name
      end

      # Tests each divided file +count+ times on +keys+ keys of each kind,
      # and returns the number of the keys that were wrong.
      def run(keys: 1000, count: 1)
        errors = 0
        count.times do |c|
          @out.puts "#{c + 1}th test #{'=' * 70}"
          safecopy_stats.size.times { |n| errors += test_file(n, keys) }
        end
        errors
      end

      private

      def test_file(n, keys)
        @out.puts "#{n + 1}th file #{'*' * 70}"
        flushing = while_writing('flushing_key', keys) do
          change_status(n, 'safecopy', :safecopy_flushed)
        end
        caching = while_writing('caching_key', keys) do
          change_status(n, 'normal', :normal)
        end
        check(flushing, keys) + check(caching, keys)
      end

      def while_writing(prefix, keys)
        writer = Writer.new(@client.call, prefix, keys).start
        writer.wait_round
        yield
        writer
      ensure
        writer&.stop
      end

      def change_status(n, status, to)
        res = nil
        10.times do
          res = @admin.request(@node_id, "set_storage_status #{n} #{status} #{@hash_name}")
          break if res == 'PUSHED'
          @out.puts "  #{res}"
          sleep @wait
        end
        raise Error, "set_storage_status #{n} #{status}: #{res}" unless res == 'PUSHED'
        sleep @wait until safecopy_stats[n] == to
        @out.puts "  #{safecopy_stats.inspect}"
      end

      # The statuses of the divided files, such as [:normal, :safecopy_flushed].
      def safecopy_stats
        key = "storages[#{@hash_name}].storage.safecopy_stats"
        line = @admin.command(@node_id, "stats #{Regexp.escape(key)}").find { |l| l.start_with?("#{key} ") }
        raise Error, "#{@node_id} has no #{@hash_name}." unless line
        line.delete_prefix("#{key} ").scan(/:(\w+)/).flatten.map(&:to_sym)
      end

      def check(writer, keys)
        client = @client.call
        keys.times.count do |i|
          key = "#{writer.prefix}_#{i}"
          got = client.get(key)
          next false if got == writer.expected(i)
          @out.puts "error k=#{key} #{got.inspect} (expected #{writer.expected(i)})"
          true
        end
      ensure
        client&.close
      end
    end
  end
end
