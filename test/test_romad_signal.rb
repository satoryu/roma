require 'test_helper'
require 'roma_test_utils'

# A romad that isn't a daemon stops by INT and TERM, and closes its
# storages. Under load, the signal comes while romad handles a request,
# where an error is rescued and logged, so it must not stop romad as an
# error.
class RomadSignalTest < Test::Unit::TestCase
  include RomaTestUtils

  STOP_TIMEOUT_SEC = 10

  def setup
    FileUtils.rm_rf(DEFAULT_NODES.map { |node| "#{Roma::Config::STORAGE_PATH}/#{node}" })
    system("#{ruby_path} #{roma_path} mkroute #{DEFAULT_NODES.join(' ')} -d 3 --replication_in_host >> #{SHELL_LOG} 2>&1")
    @pids = DEFAULT_NODES.map { |node| spawn_romad(node) }
    wait_until_up(DEFAULT_NODES)
  end

  def teardown
    @pids.each do |pid|
      Process.kill(:INT, pid)
      Process.kill(:KILL, pid) unless wait_exit(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
    wait_until_down(DEFAULT_NODES)
  end

  def spawn_romad(node)
    host, port = node.split('_')
    command = [ruby_path]
    command.push('-r', "#{test_dir}/start_coverage") if ENV['COVERAGE']
    command.push(romad_path, host, '-p', port, '--config', "#{test_dir}/#{DEFAULT_CONFIG}",
                 '--replication_in_host')
    Process.spawn(*command, %i(out err) => [SHELL_LOG, 'a'])
  end

  # Returns the status of the process +pid+ once it exits, or nil if it
  # doesn't within STOP_TIMEOUT_SEC.
  def wait_exit(pid)
    deadline = Time.now + STOP_TIMEOUT_SEC
    while Time.now < deadline
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      sleep 0.05
    end
    nil
  end

  # Sends requests to +node+ from some connections until the block returns.
  def under_load(node)
    host, port = node.split('_')
    stop = false
    loaders = Array.new(4) do
      Thread.new do
        sock = TCPSocket.new(host, port)
        until stop
          sock.write("get key\r\n")
          break unless sock.gets
        end
      rescue SystemCallError, IOError
      ensure
        sock&.close
      end
    end
    sleep 0.5
    yield
  ensure
    stop = true
    loaders.each(&:join)
  end

  data('INT' => :INT, 'TERM' => :TERM)
  def test_stop_by_signal_under_load(signal)
    status = under_load(DEFAULT_NODES[0]) do
      Process.kill(signal, @pids[0])
      wait_exit(@pids[0])
    end
    assert_not_nil status, "romad didn't stop by #{signal} in #{STOP_TIMEOUT_SEC} seconds"
    assert_true status.success?
  end
end
