require 'rbconfig'
require 'roma/tools/admin_client'
require 'roma/tools/bench'
require 'roma/tools/error'
require 'roma/tools/mkroute'

module Roma
  module Tools
    # Starts a ring of romads, sends random requests, kills a node, and
    # checks that the others find it down.
    class TestScenario
      ROMAD = File.expand_path('../../../bin/romad', __dir__)

      # The romads run in +work_dir+ at +nodes+ ports from +port+ of
      # +hostname+. They are waited for up to +timeout+ seconds.
      def initialize(out: $stdout, work_dir: '.', hostname: 'localhost', port: 11211, nodes: 3,
                     admin: AdminClient.new, timeout: 60, poll: 1, stop_timeout: 10)
        raise Error, 'The scenario needs 2 nodes or more.' if nodes < 2
        @out = out
        @work_dir = work_dir
        @node_ids = Array.new(nodes) { |i| "#{hostname}_#{port + i}" }
        @admin = admin
        @timeout = timeout
        @poll = poll
        @stop_timeout = stop_timeout
        @pids = {}
      end

      # Raises Error if the nodes don't become as expected.
      def run
        start_ring
        @node_ids.each { |nid| wait_until("#{nid} has started.") { stat(nid, 'routing.enabled_failover') == 'true' } }
        wait_nodes(@node_ids.size)
        bench = Bench.new([@node_ids[0]], out: @out)
        requests = Thread.new { bench.run(%i(rand), num: 1000) }
        killed = @node_ids.last
        @out.puts "kill #{killed}"
        kill(killed, :KILL)
        wait_nodes(@node_ids.size - 1)
        @out.puts 'The scenario has succeeded.'
      ensure
        bench&.stop
        requests&.join
        stop_ring
      end

      private

      def start_ring
        @node_ids.each do |nid|
          Dir.glob(File.join(@work_dir, "#{nid}.{route,log}*")).each { |f| File.delete(f) }
        end
        Mkroute.new(out: @out, dir: @work_dir).create(@node_ids, divide_bits: 7, replication_in_host: true)
        @node_ids.each do |nid|
          host, port = nid.split('_')
          @pids[nid] = spawn(RbConfig.ruby, ROMAD, host, '-p', port, '--replication_in_host')
        end
      end

      # The romads, which don't run as daemons, stop by INT. One that is
      # still stopping after +stop_timeout+ seconds is killed.
      def stop_ring
        @pids.each_key { |nid| kill(nid, :INT) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @stop_timeout
        @pids.each do |nid, pid|
          sleep 0.1 until wait(pid, Process::WNOHANG) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          next if wait(pid, Process::WNOHANG)
          @out.puts "kill #{nid}, which didn't stop"
          kill(nid, :KILL)
          wait(pid)
        end
        @pids.clear
      end

      # Waits until the first node knows +count+ nodes.
      def wait_nodes(count)
        length = nil
        wait_until("#{@node_ids[0]} knows #{count} nodes.") do
          length = stat(@node_ids[0], 'routing.nodes.length')&.to_i
          length == count
        end
      rescue Error
        raise Error, "#{@node_ids[0]} knows #{length.inspect} nodes, not #{count}."
      end

      # Waits until the block returns true, and writes +message+. Raises
      # Error after the timeout.
      def wait_until(message)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        until yield
          raise Error, "Timed out: #{message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep @poll
        end
        @out.puts message
      end

      # The value of the stat +name+ of +nid+, or nil if it doesn't answer.
      def stat(nid, name)
        line = @admin.command(nid, "stats #{Regexp.escape(name)}").find { |l| l.start_with?("#{name} ") }
        line&.split(' ', 2)&.last
      rescue Error
        nil
      end

      def spawn(*cmd)
        Process.spawn(*cmd, chdir: @work_dir, out: File::NULL, err: File::NULL)
      end

      def kill(nid, signal)
        pid = @pids[nid]
        Process.kill(signal, pid) if pid
      rescue Errno::ESRCH
        nil
      end

      # Returns true if the process has exited.
      def wait(pid, flags = 0)
        @exited ||= {}
        @exited[pid] ||= !Process.wait(pid, flags).nil?
      rescue Errno::ECHILD
        @exited[pid] = true
      end
    end
  end
end
