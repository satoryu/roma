require 'test_helper'

require 'socket'

# Tests that don't change the cluster share one pair of romad processes.
class NewFuncTest < Test::Unit::TestCase
  self.test_order = :defined
  include RomaTestUtils

  class << self
    include RomaTestUtils

    def startup
      start_roma
    end

    def shutdown
      stop_roma
    end
  end

  def setup
    @sock = TCPSocket.new("localhost", 11211)
  end

  def teardown
    @sock.close if @sock
  end

  def test_jaro_winkler
    @sock.write("staat\r\n")
    assert_equal("", @sock.gets.chomp)
    assert_equal("ERROR: 'staat' is not roma command.", @sock.gets.chomp)
    assert_equal("Did you mean this?", @sock.gets.chomp)
    assert_equal("\tstat", @sock.gets.chomp)

    @sock.write("outingdump yaml\r\n")
    assert_equal("", @sock.gets.chomp)
    assert_equal("ERROR: 'outingdump' is not roma command.", @sock.gets.chomp)
    assert_equal("Did you mean this?", @sock.gets.chomp)
    assert_equal("\troutingdump", @sock.gets.chomp)

    @sock.write("hoge\r\n")
    assert_equal("ERROR: 'hoge' is not roma command. Please check command.", @sock.gets.chomp)
    assert_equal("(closing telnet connection command is 'quit')", @sock.gets.chomp)
  end

  def test_stat_log_level
    @sock.write("stat log_level\r\n")
    assert_equal("stats.log_level debug", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)
  end

  def test_stat_failover
    @sock.write("stat failover\r\n")
    assert_equal("routing.enabled_failover false", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)
  end

  def test_stat_secondary
    @sock.write("stat secondary\r\n")
    column, param = @sock.gets.chomp.split("\s")
    assert_equal("routing.secondary1", column)
    assert_equal(true, param.to_i > 0)
    assert_equal("END", @sock.gets.chomp)
  end

  def test_stat_latency
    @sock.write("stat latency\r\n")
    assert_equal("stats.hilatency_warn_time 5.0", @sock.gets.chomp)
    assert_equal("stats.latency_log false", @sock.gets.chomp)
    assert_equal('stats.latency_check_cmd ["get", "set", "delete"]', @sock.gets.chomp)
    assert_equal("stats.latency_check_time_count false", @sock.gets.chomp)
  end

  def test_auto_recover_stat
    @sock.write("stat recover\r\n")
    assert_equal("stats.run_recover false", @sock.gets.chomp)
    assert_equal("routing.auto_recover false", @sock.gets.chomp)
    assert_equal("routing.auto_recover_status waiting", @sock.gets.chomp)
    assert_equal("routing.auto_recover_time 1800", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)
  end

  def test_stat_trans_timeout
    @sock.write("stat trans\r\n")
    assert_equal("stats.routing_trans_timeout 10800", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)
  end

  def test_stat_routing_event
    @sock.write("stat routing.event\r\n")
    assert_equal('routing.event []', @sock.gets.chomp)
    assert_equal('routing.event_limit_line 1000', @sock.gets.chomp)
    assert_equal('END', @sock.gets.chomp)
  end

  def test_adm_tool_sendcmd
    res = `#{bin_dir}/roma-adm`
    assert_equal('Argument Error: roma-adm [adm-command] [port No.]', res.chomp)

    res = `#{bin_dir}/roma-adm -h`
    assert_match(/usage:roma-adm \[command\] \[port No.\]\n\s+-h, --help\s+Show this message/, res.chomp)

    res = `#{bin_dir}/roma-adm whoami 11211`
    assert_equal(".\r\nROMA", res.chomp)
  end

  def test_romad_option
    res = `#{bin_dir}/romad -h`
    assert_equal("usage:romad [options] address
    -d, --daemon
    -j, --join [address:port]
    -p, --port [PORT]
        --verbose
    -n, --name [name]
        --enabled_repeathost         Allow redundancy to same host
        --replication_in_host        Allow redundancy to same host
        --disabled_cmd_protect       Command protection disable while starting
        --config [file path of the config.rb]
    -h, --help                       Show this message
    -v, --version                    Show version", res.chomp)
  end

  def test_waiting_node
    log = File.read("./localhost_11211.log")
    assert_equal(true, log.include?("I'm waiting for booting the localhost_11211 instance"))
  end

end

# Tests that change settings or nodes start new romad processes each time.
# Each setting command is covered by test_sys_command.rb. The ones here check
# that relaying to the other node works through romad.
class NewFuncChangingClusterTest < Test::Unit::TestCase
  self.test_order = :defined
  include RomaTestUtils

  def setup
    start_roma
    @sock = TCPSocket.new("localhost", 11211)
  end

  def teardown
    @sock.close if @sock
    stop_roma
  end

  def test_switch_dns_caching
    @sock.write("stat dns\r\n")
    assert_equal("dns_caching false", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)

    @sock.write("switch_dns_caching on \r\n")
    assert_equal('{"localhost_11212" => "ENABLED", "localhost_11211" => "ENABLED"}', @sock.gets.chomp)
    @sock.write("stat dns\r\n")
    assert_equal("dns_caching true", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)

    @sock.write("switch_dns_caching off \r\n")
    assert_equal('{"localhost_11212" => "DISABLED", "localhost_11211" => "DISABLED"}', @sock.gets.chomp)
    @sock.write("stat dns\r\n")
    assert_equal("dns_caching false", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)

    @sock.write("switch_dns_caching off \r\n")
    assert_equal('{"localhost_11212" => "DISABLED", "localhost_11211" => "DISABLED"}', @sock.gets.chomp)
    @sock.write("stat dns\r\n")
    assert_equal("dns_caching false", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)
  end

  def test_set_latency_avg_calc_rule
    @sock.write("set_latency_avg_calc_rule off\r\n")
    assert_equal('{"localhost_11212" => "DEACTIVATED", "localhost_11211" => "DEACTIVATED"}', @sock.gets.chomp)
    @sock.write("stat latency\r\n")
    assert_equal("stats.hilatency_warn_time 5.0", @sock.gets.chomp)
    assert_equal("stats.latency_log false", @sock.gets.chomp)
    assert_equal('stats.latency_check_cmd []', @sock.gets.chomp)
    assert_equal("stats.latency_check_time_count false", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)

    @sock.write("set_latency_avg_calc_rule on 30 get set\r\n")
    assert_equal('{"localhost_11212" => "ACTIVATED", "localhost_11211" => "ACTIVATED"}', @sock.gets.chomp)
    @sock.write("stat latency\r\n")
    assert_equal("stats.hilatency_warn_time 5.0", @sock.gets.chomp)
    assert_equal("stats.latency_log true", @sock.gets.chomp)
    assert_equal('stats.latency_check_cmd ["get", "set"]', @sock.gets.chomp)
    assert_equal("stats.latency_check_time_count 30", @sock.gets.chomp)
    assert_equal("END", @sock.gets.chomp)
  end

  def test_add_routing_event
    @sock.write("switch_failover on\r\n")
    assert_equal('{"localhost_11212" => "ENABLED", "localhost_11211" => "ENABLED"}', @sock.gets.chomp)

    # Fail over at the first failed check (once a second) instead of the fifth.
    @sock.write("set_threshold_for_failover 1\r\n")
    @sock.gets
    stop_roma_node('localhost_11212')

    # wait failover
    wait_for('the leave event') do
      @sock.write("stat routing.event$\r\n")
      line = @sock.gets.chomp
      @sock.gets # END
      line != 'routing.event []'
    end
    @sock.write("stat routing.event$\r\n")
    assert_match(/routing\.event \["[-T\d:\.]+ leave localhost_11212"\]/, @sock.gets.chomp)
    assert_equal('END', @sock.gets.chomp)
  end

end
