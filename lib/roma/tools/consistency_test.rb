require 'roma/tools/bench'
require 'roma/tools/text_client'

module Roma
  module Tools
    # Sets the keys to the number of the round, and checks that every key
    # has it, round after round.
    class ConsistencyTest
      def initialize(node_ids, out: $stdout, interval: 10, client: TextClient.new(node_ids))
        @out = out
        @interval = interval
        @client = client
        @stats = Bench::Stats.new
      end

      # Runs +rounds+ rounds on key_0 ... of +keys+ keys, or forever, and
      # returns the number of the keys that were wrong.
      def run(keys: 10_000, rounds: nil)
        errors = 0
        @stats.reporting(@out, @interval) do
          (1..rounds).each do |n|
            keys.times { |i| set(i, n) }
            keys.times { |i| errors += 1 unless check(i, n) }
            @out.puts "#{n} loop has finished." if n % 100 == 0
          end
        end
        errors
      ensure
        @client.close
      end

      private

      def set(i, n)
        res = @stats.measure { @client.set("key_#{i}", n.to_s) }
        @out.puts "set k=key_#{i} #{res}" unless res == 'STORED'
      rescue Error => e
        @out.puts "set k=key_#{i} #{e.message}"
      end

      def check(i, n)
        res = @stats.measure { @client.get("key_#{i}") }
        return true if res == n.to_s
        @out.puts "error k=key_#{i} #{res.inspect}"
        false
      rescue Error => e
        @out.puts "error k=key_#{i} #{e.message}"
        false
      end
    end
  end
end
