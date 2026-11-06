require 'test_helper'
require 'open3'
require 'roma_test_utils'

# The server stops by INT and TERM, and closes its storages, whether it is
# a daemon or not. Under load, the signal comes while the server handles a
# request, where an error is rescued and logged, so it must not stop the
# server as an error.
class ServerSignalTest < Test::Unit::TestCase
  include RomaTestUtils

  STOP_TIMEOUT_SEC = 10

  def setup
    FileUtils.rm_rf(DEFAULT_NODES.map { |node| "#{Roma.config.storage.path}/#{node}" })
    system("#{ruby_path} #{roma_path} route create #{DEFAULT_NODES.join(' ')} -d 3 --replication_in_host >> #{SHELL_LOG} 2>&1")
    @pids = []
  end

  def teardown
    @pids.each do |pid|
      Process.kill(:INT, pid)
      Process.kill(:KILL, pid) unless wait_exit(pid)
    rescue Errno::ESRCH
    end
    wait_until_down(DEFAULT_NODES)
  end

  # Starts the nodes. The first one is a daemon if +daemon+.
  def boot(daemon:)
    @pids << (daemon ? start_daemon(DEFAULT_NODES[0]) : spawn_server(DEFAULT_NODES[0]))
    @pids << spawn_server(DEFAULT_NODES[1])
    wait_until_up(DEFAULT_NODES)
  end

  def server_args(node)
    host, port = node.split('_')
    [ruby_path, roma_path, 'server', host, '-p', port, '--config', "#{test_dir}/#{DEFAULT_CONFIG}",
     '--replication_in_host']
  end

  def spawn_server(node)
    command = server_args(node)
    command.insert(1, '-r', "#{test_dir}/start_coverage") if ENV['COVERAGE']
    pid = Process.spawn(*command, %i(out err) => [SHELL_LOG, 'a'])
    Process.detach(pid)
    pid
  end

  # Returns the pid of the daemon, which the server writes to the standard error.
  def start_daemon(node)
    _, err, status = Open3.capture3(*server_args(node), '-d')
    assert_true status.success?, err
    err[/^\d+$/].to_i
  end

  # Waits until the process +pid+ exits, and returns false if it doesn't in
  # STOP_TIMEOUT_SEC.
  def wait_exit(pid)
    deadline = Time.now + STOP_TIMEOUT_SEC
    while Time.now < deadline
      Process.kill(0, pid)
      sleep 0.05
    end
    false
  rescue Errno::ESRCH
    true
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

  def stopped_logs(node)
    File.read("#{Roma.config.log.path}/#{node}.log").scan("The server has stopped: #{node}").size
  end

  data('INT' => [:INT, false], 'TERM' => [:TERM, false],
       'INT, daemon' => [:INT, true], 'TERM, daemon' => [:TERM, true])
  def test_stop_by_signal_under_load(data)
    signal, daemon = data
    boot(daemon: daemon)
    node = DEFAULT_NODES[0]
    stopped = stopped_logs(node)
    exited = under_load(node) do
      Process.kill(signal, @pids[0])
      wait_exit(@pids[0])
    end
    assert_true exited, "the server didn't stop by #{signal} in #{STOP_TIMEOUT_SEC} seconds"
    # The storages are closed.
    assert_equal stopped + 1, stopped_logs(node)
  end
end
