require 'pathname'
require 'fileutils'
require 'rbconfig'
require 'socket'
require 'roma/config'
require 'roma/messaging/con_pool'
require 'roma/logging/rlogger'
require 'roma_test_client'

module RomaTestUtils
  DEFAULT_CONFIG = 'config4test.rb'
  DEFAULT_HOST = 'localhost'
  DEFAULT_IP = '127.0.0.1'
  DEFAULT_PORTS = %w(11211 11212)
  DEFAULT_NODES = DEFAULT_PORTS.map { |port| "#{DEFAULT_HOST}_#{port}" }
  DEFAULT_TIMEOUT_SEC = 90
  REPLICA_PORTS = %w(21211 21212)
  REPLICA_NODES = REPLICA_PORTS.map { |port| "#{DEFAULT_HOST}_#{port}" }
  SHELL_LOG = 'roma_test_outputs.log'

  # Extend a test class with it to start romad once for the class instead of
  # once for each test. The tests then share the data stored in romad, so
  # each test must not depend on what the others store.
  module RomaPerClass
    def self.extended(test_class)
      test_class.singleton_class.include(RomaTestUtils)
    end

    def startup
      start_roma
    end

    def shutdown
      stop_roma
    end
  end

  Roma::Logging::RLogger.create_singleton_instance("#{Roma::Config::LOG_PATH}/roma_test.log",
                                                   Roma::Config::LOG_SHIFT_AGE,
                                                   Roma::Config::LOG_SHIFT_SIZE)

  module_function

  def start_roma(conf = DEFAULT_CONFIG, div_bits: 3, replication_in_host: true)
    FileUtils.rm_rf(Dir.glob("#{Roma::Config::STORAGE_PATH}/#{DEFAULT_NODES[0][0..-2]}?*"))
    FileUtils.rm_rf(Dir.glob("#{Roma::Config::STORAGE_PATH}/#{DEFAULT_IP}_#{DEFAULT_PORTS[0][0..-2]}?*"))

    system("#{ruby_path} #{roma_path} mkroute #{DEFAULT_NODES.join(' ')} -d #{div_bits} --replication_in_host >> #{SHELL_LOG} 2>&1")
    boot_nodes(DEFAULT_NODES, conf, replication_in_host)
  end

  def start_roma_replica(conf = DEFAULT_CONFIG, div_bits: 3, replication_in_host: true)
    FileUtils.rm_rf(Dir.glob("#{Roma::Config::STORAGE_PATH}/#{REPLICA_NODES[0][0..-2]}?*"))
    FileUtils.rm_rf(Dir.glob("#{Roma::Config::STORAGE_PATH}/#{DEFAULT_IP}_#{REPLICA_PORTS[0][0..-2]}?*"))

    system("#{ruby_path} #{roma_path} mkroute #{REPLICA_NODES.join(' ')} -d #{div_bits} --replication_in_host >> #{SHELL_LOG} 2>&1")
    boot_nodes(REPLICA_NODES, conf, replication_in_host)
  end

  # Boots the nodes at the same time and waits until they accept connections.
  def boot_nodes(nodes, conf, replication_in_host)
    pids = nodes.map do |node|
      Process.spawn(romad_command(node, conf, replication_in_host))
    end
    if ENV['COVERAGE']
      # romad runs in the foreground and writes its coverage when it stops.
      pids.each { |pid| Process.detach(pid) }
    else
      # Each command returns once romad daemonizes.
      pids.each { |pid| Process.wait(pid) }
    end
    wait_until_up(nodes)
  end

  def join_roma(node, conf = DEFAULT_CONFIG, replication_in_host: true)
    do_command_romad(node, conf, replication_in_host, true)
  end

  def do_command_romad(node, conf, replication_in_host = true, is_join = false)
    system(romad_command(node, conf, replication_in_host, is_join, daemon: true))
  end

  # With COVERAGE, romad runs in the foreground: when it forks to become a
  # daemon, Ruby resets the coverage counts in the child, and the coverage of
  # loading lib would be lost.
  def romad_command(node, conf, replication_in_host, is_join = false, daemon: !ENV['COVERAGE'])
    host, port = node.split('_')
    command = [ruby_path]
    command.push('-r', "#{test_dir}/start_coverage") if ENV['COVERAGE']
    command.push(
      romad_path, host,
      '-p', port,
      '--verbose', '--disabled_cmd_protect',
      '--config', "#{test_dir}/#{conf}"
    )
    command << '-d' if daemon
    command << '--replication_in_host' if replication_in_host
    command << "-j #{DEFAULT_NODES[0]}" if is_join
    command << ">> #{SHELL_LOG} 2>&1"
    command.join(' ')
  end

  def get_client
    RomaTestClient.new(DEFAULT_NODES)
  end

  def wait_join(node)
    client = get_client
    wait_count = 0
    sleep 5

    until client.rttable.nodes.include?(node)
      sleep 1
      client.update_rttable
      wait_count += 1
      fail "#{__method__} timeout" if wait_count > DEFAULT_TIMEOUT_SEC
    end

    while client.stats(node: node)['stats.run_join'] == 'true'
      sleep 1
      wait_count += 1
      fail "#{__method__} timeout" if wait_count > DEFAULT_TIMEOUT_SEC
    end
  end

  def wait_failover(down_node)
    client = get_client
    stats_node = down_node == DEFAULT_NODES[0] ? DEFAULT_NODES[1] : DEFAULT_NODES[0]
    wait_count = 0
    sleep 1

    while client.stats(node: stats_node)['routing.nodes'] =~ /#{down_node}/
      sleep 1
      wait_count += 1
      fail "#{__method__} timeout" if wait_count > DEFAULT_TIMEOUT_SEC
    end
  end

  def wait_release(node)
    client = get_client
    wait_count = 0
    sleep 1

    while client.stats(node: node)['stats.run_release'] == 'true'
      sleep 1
      wait_count += 1
      fail "#{__method__} timeout" if wait_count > DEFAULT_TIMEOUT_SEC
    end
  end

  def stop_roma
    balse_message = %w(balse yes)
    send_message(messages: balse_message)
    RomaTestClient.close_all
    Roma::Messaging::ConPool.instance.close_all
    wait_until_down(DEFAULT_NODES)
  end

  def stop_roma_replica
    balse_message = %w(balse yes)
    send_message(messages: balse_message, node: REPLICA_NODES[0])
    RomaTestClient.close_all
    Roma::Messaging::ConPool.instance.close_all
    wait_until_down(REPLICA_NODES)
  end

  def stop_roma_node(node)
    send_message(messages: 'rbalse', node: node)
    RomaTestClient.close_all
    Roma::Messaging::ConPool.instance.close_all
    wait_until_down([node])
  end

  def release_roma_node(node)
    send_message(messages: 'release', node: node)
  end

  # Asserts that the block returns +expected+ within +timeout+ seconds.
  # Use it to wait for asynchronous work, such as replication or expiry.
  def assert_eventually_equal(expected, timeout: DEFAULT_TIMEOUT_SEC)
    deadline = Time.now + timeout
    loop do
      actual = yield
      return assert_equal(expected, actual) if actual == expected || Time.now > deadline
      sleep 0.05
    end
  end

  # Parses a reply relayed to every node, such as
  # {"localhost_11212" => "CREATED", "localhost_11211" => "CREATED"}.
  def parse_node_replies(line)
    line.scan(/"([^"]*)" => "([^"]*)"/).to_h
  end

  # Waits until every node accepts connections.
  def wait_until_up(nodes)
    wait_for("#{nodes} to start") { nodes.all? { |node| listening?(node) } }
  end

  # Waits until every node stops, so that the next romad can use its port.
  # (romad exits at once if the same node is already running.)
  def wait_until_down(nodes)
    wait_for("#{nodes} to stop") { nodes.none? { |node| listening?(node) } }
  end

  private

  def wait_for(what)
    deadline = Time.now + DEFAULT_TIMEOUT_SEC
    until yield
      fail "timed out waiting for #{what}" if Time.now > deadline
      sleep 0.05
    end
  end

  def listening?(node)
    host, port = node.split('_')
    TCPSocket.new(host, port).close
    true
  rescue SystemCallError
    false
  end

  def base_dir
    Pathname(__FILE__).dirname.parent.expand_path
  end

  def bin_dir
    base_dir + 'bin'
  end

  def test_dir
    base_dir + 'test'
  end

  def roma_path
    (bin_dir + 'roma').to_s
  end

  def romad_path
    (bin_dir + 'romad').to_s
  end

  def ruby_path
    File.join(RbConfig::CONFIG['bindir'],
              RbConfig::CONFIG['ruby_install_name'])
  end

  def send_message(messages: [], node: DEFAULT_NODES[0])
    conn = Roma::Messaging::ConPool.instance.get_connection(node)
    return false unless conn

    messages = [messages] if messages.class == String

    messages.each do |message|
      conn.write "#{message}\r\n"
      conn.gets
    end
  rescue => e
    puts "#{e} #{$ERROR_POSITION}"
  ensure
    Roma::Messaging::ConPool.instance.return_connection(node, conn)
  end
end
