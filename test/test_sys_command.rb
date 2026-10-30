require 'test_helper'
require 'command_test_harness'

# Unit tests for the system commands that change settings on every node.
#
# Most of them come in pairs. set_<name> checks its arguments, relays
# rset_<name> to the other nodes, changes the setting on this node and
# replies with the result of each node. rset_<name> only changes the setting
# on the node that receives it.
class SysCommandTest < Test::Unit::TestCase
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID

  def setup
    @conn = CommandTestHarness.new
  end

  def teardown
    @conn.close
  end

  # The reply of set_<name> when every node replied +reply+.
  def relayed(reply)
    "#{{ OTHER_NID => 'STORED', NID => reply }}\r\n"
  end

  # Settings kept in Roma::Stats:
  #   name => [attribute, value, value stored, invalid value]
  STATS_SETTINGS = {
    'hilatency_warn_time' => [:hilatency_warn_time, '2.5', 2.5, '0'],
    'routing_trans_timeout' => [:routing_trans_timeout, '60', 60.0, '0'],
    'spushv_read_timeout' => [:spushv_read_timeout, '10', 10, '0'],
    'reqpushv_timeout_count' => [:reqpushv_timeout_count, '5', 5, '-1'],
    'spushv_klength_warn' => [:spushv_klength_warn, '2048', 2048, '0'],
    'spushv_vlength_warn' => [:spushv_vlength_warn, '2048', 2048, '0'],
    'log_shift_size' => [:log_shift_size, '4096', 4096, '0'],
  }

  data(STATS_SETTINGS)
  def test_set(data)
    name = data_label
    attr, value, stored, = data
    assert_equal relayed('STORED'), @conn.request("set_#{name} #{value}")
    assert_equal ["rset_#{name} #{value}\r\n"], @conn.broadcasts
    assert_equal stored, @conn.stats.send(attr)
  end

  data(STATS_SETTINGS)
  def test_rset(data)
    name = data_label
    attr, value, stored, = data
    assert_equal "STORED\r\n", @conn.request("rset_#{name} #{value}")
    assert_equal [], @conn.broadcasts
    assert_equal stored, @conn.stats.send(attr)
  end

  data(STATS_SETTINGS)
  def test_invalid_value(data)
    name = data_label
    attr, _, _, invalid = data
    before = @conn.stats.send(attr)
    %w(set rset).each do |prefix|
      assert_match(/\ACLIENT_ERROR .+\r\n\z/, @conn.request("#{prefix}_#{name} #{invalid}"))
    end
    assert_equal [], @conn.broadcasts
    assert_equal before, @conn.stats.send(attr)
  end

  data(STATS_SETTINGS)
  def test_wrong_number_of_arguments(data)
    name = data_label
    %W(set_#{name} rset_#{name} set_#{name}\s1\s2).each do |line|
      assert_equal "CLIENT_ERROR number of arguments\r\n", @conn.request(line)
    end
    assert_equal [], @conn.broadcasts
  end

  # Other commands whose replies to a wrong number of arguments ended with
  # "\n\r" instead of "\r\n".
  data('rswitch_replication' => 'rswitch_replication',
       'set_gui_run_snapshot' => 'set_gui_run_snapshot',
       'set_gui_last_snapshot' => 'set_gui_last_snapshot',
       'rset_gui_last_snapshot' => 'rset_gui_last_snapshot')
  def test_number_of_arguments_error_ends_with_crlf(command)
    assert_equal "CLIENT_ERROR number of arguments\r\n", @conn.request(command)
  end

  def test_log_shift_size_is_set_on_the_logger
    @conn.request('set_log_shift_size 4096')
    assert_equal 4096, @conn.log.shift_size
  end

  data('number' => ['7', 7], 'zero' => ['0', 0], 'name' => ['daily', 'daily'])
  def test_set_log_shift_age(data)
    value, stored = data
    assert_equal relayed('STORED'), @conn.request("set_log_shift_age #{value}")
    assert_equal ["rset_log_shift_age #{value}\r\n"], @conn.broadcasts
    assert_equal stored, @conn.stats.log_shift_age
    assert_equal stored, @conn.log.shift_age
    assert_equal "STORED\r\n", @conn.request("rset_log_shift_age #{value}")
  end

  def test_set_log_shift_age_with_invalid_value
    assert_equal "CLIENT_ERROR invalid arguments\r\n", @conn.request('set_log_shift_age yearly')
    assert_equal "CLIENT_ERROR invalid arguments\r\n", @conn.request('rset_log_shift_age yearly')
    assert_equal 0, @conn.stats.log_shift_age
  end

  data('debug' => ['debug', Logger::DEBUG], 'info' => ['info', Logger::INFO],
       'warn' => ['WARN', Logger::WARN], 'error' => ['error', Logger::ERROR])
  def test_set_log_level(data)
    value, level = data
    # set_log_level changes only this node.
    assert_equal "STORED\r\n", @conn.request("set_log_level #{value}")
    assert_equal level, @conn.log.level
    assert_equal value.downcase, @conn.stats.log_level
    assert_equal [], @conn.broadcasts
  end

  def test_set_log_level_with_invalid_value
    assert_equal "CLIENT_ERROR no match log-level string\r\n", @conn.request('set_log_level verbose')
    assert_equal "CLIENT_ERROR number of arguments (0 for 1)\r\n", @conn.request('set_log_level')
  end

  def test_switch_failover
    @conn.relay_reply = 'ENABLED'
    assert_equal "#{{ OTHER_NID => 'ENABLED', NID => 'ENABLED' }}\r\n", @conn.request('switch_failover on')
    assert_true @conn.rttable.enabled_failover
    assert_equal ["rswitch_failover on\r\n"], @conn.broadcasts

    @conn.relay_reply = 'DISABLED'
    assert_equal "#{{ OTHER_NID => 'DISABLED', NID => 'DISABLED' }}\r\n", @conn.request('switch_failover off')
    assert_false @conn.rttable.enabled_failover
  end

  def test_switch_failover_with_invalid_value
    @conn.relay_reply = 'NOTSWITCHED'
    assert_equal "#{{ OTHER_NID => 'NOTSWITCHED', NID => 'NOTSWITCHED' }}\r\n",
                 @conn.request('switch_failover maybe')
    assert_false @conn.rttable.enabled_failover
    assert_equal "CLIENT_ERROR number of arguments\r\n", @conn.request('switch_failover')
  end

  def test_rswitch_failover
    assert_equal "ENABLED\r\n", @conn.request('rswitch_failover on')
    assert_true @conn.rttable.enabled_failover
    assert_equal "DISABLED\r\n", @conn.request('rswitch_failover off')
    assert_false @conn.rttable.enabled_failover
    assert_equal "NOTSWITCHED\r\n", @conn.request('rswitch_failover maybe')
    assert_equal [], @conn.broadcasts
  end

  def test_set_wb_shift_size
    assert_equal relayed('STORED'), @conn.request('set_wb_shift_size 2048')
    assert_equal ["rset_wb_shift_size 2048\r\n"], @conn.broadcasts
    assert_equal 2048, @conn.romad.wb_writer.shift_size
    assert_equal "STORED\r\n", @conn.request('rset_wb_shift_size 4096')
    assert_equal 4096, @conn.romad.wb_writer.shift_size
    assert_equal "CLIENT_ERROR length must be greater than zero\r\n", @conn.request('set_wb_shift_size 0')
  end

  def test_wb_command_map
    reply = @conn.request('wb_command_map {:set=>1,:delete=>2}')
    map = { set: 1, delete: 2 }
    assert_equal "#{{ OTHER_NID => 'STORED', NID => map.inspect }}\r\n", reply
    assert_equal ["rwb_command_map {:set=>1,:delete=>2}\r\n"], @conn.broadcasts
    assert_equal map, @conn.stats.wb_command_map
  end

  def test_rwb_command_map
    assert_equal "#{{ set: 1 }}\r\n", @conn.request('rwb_command_map {:set=>1}')
    assert_equal({ set: 1 }, @conn.stats.wb_command_map)
  end

  def test_wb_command_map_with_invalid_value
    assert_equal "CLIENT_ERROR hash string parse error\r\n", @conn.request('wb_command_map set=1')
    assert_equal "CLIENT_ERROR number of arguments\r\n", @conn.request('wb_command_map')
    assert_equal({}, @conn.stats.wb_command_map)
  end
end

# Commands that change the latency measurement.
class SysCommandLatencyTest < Test::Unit::TestCase
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID

  def setup
    @conn = CommandTestHarness.new
  end

  def teardown
    @conn.close
  end

  def replies(reply)
    "#{{ OTHER_NID => 'STORED', NID => reply }}\r\n"
  end

  def test_set_latency_avg_calc_rule_on
    assert_equal replies('ACTIVATED'), @conn.request('set_latency_avg_calc_rule on 30 get set')
    assert_equal ["rset_latency_avg_calc_rule on 30 get set\r\n"], @conn.broadcasts
    assert_equal %w(get set), @conn.stats.latency_check_cmd
    assert_equal 30, @conn.stats.latency_check_time_count
    assert_true @conn.stats.latency_log
  end

  def test_set_latency_avg_calc_rule_off
    @conn.request('set_latency_avg_calc_rule on 30 get')
    assert_equal replies('DEACTIVATED'), @conn.request('set_latency_avg_calc_rule off')
    assert_equal [], @conn.stats.latency_check_cmd
    assert_false @conn.stats.latency_check_time_count
    assert_false @conn.stats.latency_log
  end

  data('mode' => ['set_latency_avg_calc_rule maybe',
                  "CLIENT_ERROR argument 1: please input \"on\" or \"off\"\r\n"],
       'no count' => ['set_latency_avg_calc_rule on 0 get',
                      "CLIENT_ERROR number of arguments (0 for 3) and <count> must be greater than zero\r\n"],
       'off with args' => ['set_latency_avg_calc_rule off 30',
                           "CLIENT_ERROR number of arguments (0 for 1, or more 3)\r\n"],
       'system command' => ['set_latency_avg_calc_rule on 30 balse', "NOT SUPPORT [balse] command\r\n"],
       'unknown command' => ['set_latency_avg_calc_rule on 30 hoge', "NOT SUPPORT [hoge] command\r\n"])
  def test_set_latency_avg_calc_rule_with_invalid_arguments(data)
    line, reply = data
    assert_equal reply, @conn.request(line)
    assert_equal reply, @conn.request("r#{line}")
    assert_equal [], @conn.broadcasts
    assert_equal %w(get set delete), @conn.stats.latency_check_cmd
  end

  def test_rset_latency_avg_calc_rule
    assert_equal "ACTIVATED\r\n", @conn.request('rset_latency_avg_calc_rule on 10 delete')
    assert_equal %w(delete), @conn.stats.latency_check_cmd
    assert_equal 10, @conn.stats.latency_check_time_count
    assert_equal "DEACTIVATED\r\n", @conn.request('rset_latency_avg_calc_rule off')
    assert_equal [], @conn.stats.latency_check_cmd
    assert_equal [], @conn.broadcasts
  end

  def test_add_and_del_latency_avg_calc_cmd
    assert_equal replies('DELETED'), @conn.request('del_latency_avg_calc_cmd set delete')
    assert_equal ["rdel_latency_avg_calc_cmd set delete\r\n"], @conn.broadcasts
    assert_equal %w(get), @conn.stats.latency_check_cmd

    assert_equal replies('SET'), @conn.request('add_latency_avg_calc_cmd delete')
    assert_equal "radd_latency_avg_calc_cmd delete\r\n", @conn.broadcasts.last
    assert_equal %w(get delete), @conn.stats.latency_check_cmd
  end

  def test_radd_and_rdel_latency_avg_calc_cmd
    assert_equal "DELETED\r\n", @conn.request('rdel_latency_avg_calc_cmd get')
    assert_equal %w(set delete), @conn.stats.latency_check_cmd
    assert_equal "SET\r\n", @conn.request('radd_latency_avg_calc_cmd get')
    assert_equal %w(set delete get), @conn.stats.latency_check_cmd
    assert_equal [], @conn.broadcasts
  end

  def test_add_latency_avg_calc_cmd_with_invalid_arguments
    assert_equal "ALREADY SET [get] command\r\n", @conn.request('add_latency_avg_calc_cmd get')
    assert_equal "NOT SUPPORT [balse] command\r\n", @conn.request('add_latency_avg_calc_cmd balse')
    assert_equal "CLIENT_ERROR number of arguments (0 for 2)\r\n", @conn.request('add_latency_avg_calc_cmd')
    assert_equal "[hoge] command is NOT set\r\n", @conn.request('del_latency_avg_calc_cmd hoge')
    assert_equal [], @conn.broadcasts
    assert_equal %w(get set delete), @conn.stats.latency_check_cmd
  end

  def test_radd_latency_avg_calc_cmd_checks_every_command
    assert_equal "NOT SUPPORT [balse] command\r\n", @conn.request('radd_latency_avg_calc_cmd balse')
    assert_equal "NOT SUPPORT [hoge] command\r\n", @conn.request('radd_latency_avg_calc_cmd hoge')
    assert_equal %w(get set delete), @conn.stats.latency_check_cmd
  end

  def test_chg_latency_avg_calc_time_count
    assert_equal replies('CHANGED'), @conn.request('chg_latency_avg_calc_time_count 60')
    assert_equal ["rchg_latency_avg_calc_time_count 60\r\n"], @conn.broadcasts
    assert_equal 60, @conn.stats.latency_check_time_count
    assert_true @conn.stats.latency_log

    assert_equal replies('CHANGED'), @conn.request('chg_latency_avg_calc_time_count nil')
    assert_false @conn.stats.latency_check_time_count
    assert_false @conn.stats.latency_log
  end

  def test_chg_latency_avg_calc_time_count_with_invalid_value
    assert_equal "<count> must be greater than zero or nil[DEACTIVATE]\r\n",
                 @conn.request('chg_latency_avg_calc_time_count 0')
    assert_equal [], @conn.broadcasts
  end

  def test_rchg_latency_avg_calc_time_count
    assert_equal "CHANGED\r\n", @conn.request('rchg_latency_avg_calc_time_count 60')
    assert_equal 60, @conn.stats.latency_check_time_count
    assert_equal "<count> must be greater than zero\r\n", @conn.request('rchg_latency_avg_calc_time_count 0')
  end

  def test_rchg_latency_avg_calc_time_count_nil
    @conn.request('rchg_latency_avg_calc_time_count 60')
    assert_equal "CHANGED\r\n", @conn.request('rchg_latency_avg_calc_time_count nil')
    # The same as chg_latency_avg_calc_time_count nil on the relaying node.
    assert_false @conn.stats.latency_check_time_count
    assert_false @conn.stats.latency_log
  end
end

# Commands that change settings shared by the whole process, such as the
# connection pools. Each test puts the setting back.
class SysCommandProcessSettingTest < Test::Unit::TestCase
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID

  def setup
    @conn = CommandTestHarness.new
    @saved = {
      con_pool: [Roma::Messaging::ConPool.instance.maxlength, Roma::Messaging::ConPool.instance.expire_time],
      em_con_pool: [Roma::Event::EMConPool.instance.maxlength, Roma::Event::EMConPool.instance.expire_time],
      connection_expire_time: Roma::Event::Handler.connection_expire_time,
      ccl: Roma::Event::Handler.get_ccl,
    }
  end

  def teardown
    @conn.close
    Roma::Messaging::ConPool.instance.maxlength, Roma::Messaging::ConPool.instance.expire_time = @saved[:con_pool]
    Roma::Event::EMConPool.instance.maxlength, Roma::Event::EMConPool.instance.expire_time = @saved[:em_con_pool]
    Roma::Event::Handler.connection_expire_time = @saved[:connection_expire_time]
    Roma::Event::Handler.set_ccl(@saved[:ccl])
    Roma::DNSCache.instance.disable_dns_cache
  end

  def replies(reply)
    "#{{ OTHER_NID => 'STORED', NID => reply }}\r\n"
  end

  #   name => [value, how to read the setting]
  POOL_SETTINGS = {
    'connection_pool_maxlength' => ['20', -> { Roma::Messaging::ConPool.instance.maxlength }],
    'emconnection_pool_maxlength' => ['20', -> { Roma::Event::EMConPool.instance.maxlength }],
    'connection_pool_expire_time' => ['60', -> { Roma::Messaging::ConPool.instance.expire_time }],
    'emconnection_pool_expire_time' => ['60', -> { Roma::Event::EMConPool.instance.expire_time }],
    'accepted_connection_expire_time' => ['120', -> { Roma::Event::Handler.connection_expire_time }],
  }

  data(POOL_SETTINGS)
  def test_set(data)
    name = data_label
    value, setting = data
    assert_equal replies('STORED'), @conn.request("set_#{name} #{value}")
    assert_equal ["rset_#{name} #{value}\r\n"], @conn.broadcasts
    assert_equal value.to_i, setting.call
  end

  data(POOL_SETTINGS)
  def test_rset(data)
    name = data_label
    value, setting = data
    assert_equal "STORED\r\n", @conn.request("rset_#{name} #{value}")
    assert_equal value.to_i, setting.call
    assert_equal "CLIENT_ERROR number of arguments\r\n", @conn.request("rset_#{name}")
  end

  def test_set_connection_pool_maxlength_with_invalid_value
    %w(connection_pool_maxlength emconnection_pool_maxlength).each do |name|
      assert_equal "CLIENT_ERROR length must be greater than zero\r\n", @conn.request("set_#{name} 0")
    end
    assert_equal [], @conn.broadcasts
  end

  def test_set_emconnection_pool_expire_time_zero_means_no_expiry
    @conn.request('set_emconnection_pool_expire_time 0')
    assert_equal ["rset_emconnection_pool_expire_time 2147483647\r\n"], @conn.broadcasts
    assert_equal 2_147_483_647, Roma::Event::EMConPool.instance.expire_time
  end

  def test_set_continuous_limit
    assert_equal replies('STORED'), @conn.request('set_continuous_limit 100:20:200')
    assert_equal ["rset_continuous_limit 100:20:200\r\n"], @conn.broadcasts
    assert_equal '100:20:200', Roma::Event::Handler.get_ccl
    assert_equal "STORED\r\n", @conn.request('rset_continuous_limit 10:5:20')
    assert_equal '10:5:20', Roma::Event::Handler.get_ccl
  end

  data('format' => '100:20', 'rate over 100' => '1:101:2', 'start over full' => '300:20:200')
  def test_set_continuous_limit_with_invalid_value(value)
    before = Roma::Event::Handler.get_ccl
    assert_equal replies('NOT_STORED'), @conn.request("set_continuous_limit #{value}")
    assert_equal "NOT_STORED\r\n", @conn.request("rset_continuous_limit #{value}")
    assert_equal before, Roma::Event::Handler.get_ccl
  end

  data('on' => ['on', true], 'true' => ['true', true], 'off' => ['off', false], 'false' => ['false', false])
  def test_switch_dns_caching(data)
    value, enabled = data
    reply = enabled ? 'ENABLED' : 'DISABLED'
    @conn.relay_reply = reply
    assert_equal "#{{ OTHER_NID => reply, NID => reply }}\r\n", @conn.request("switch_dns_caching #{value}")
    assert_equal ["rswitch_dns_caching #{value}\r\n"], @conn.broadcasts
    assert_equal enabled, Roma::DNSCache.instance.get_stat['dns_caching']
    assert_equal "#{reply}\r\n", @conn.request("rswitch_dns_caching #{value}")
  end
end
