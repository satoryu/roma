require 'singleton'
require 'roma/logging/rlogger'

module Roma
  class Stats
    include Singleton

    # environment options
    attr_accessor :config_path, :pid_file

    # command options
    attr_accessor :address, :port
    attr_accessor :daemon, :join_node_id, :start_with_failover, :name, :verbose, :replication_in_host,
                  :command_protection_disabled, :run_sync_routing, :run_iterate_storage, :run_storage_clean_up, :run_receive_a_vnode, :run_release, :run_join, :run_balance, :last_clean_up, :spushv_protection, :stream_show_wait, :dcnice, :clean_up_interval, :read_count, :delete_count, :out_count, :out_message_count, :redundant_count, :hilatency_warn_time, :spushv_vlength_warn, :spushv_read_timeout, :reqpushv_timeout_count, :routing_transaction_timeout, :gui_run_gather_logs, :gui_last_snapshot, :log_shift_age, :log_level

    # proc mode
    attr_accessor :enabled_vnodes_balance

    # proc status
    attr_accessor :run_recover

    # proc param
    attr_accessor :stream_copy_wait

    # compressed redundant param
    attr_accessor :compression_threshold

    # performance counter
    attr_accessor :write_count

    # for write behind
    attr_accessor :wb_command_map

    # The latency check, changed by start_latency_check and the others.
    attr_reader :latency_log, :latency_check_cmd, :latency_check_time_count, :latency_data

    # for vnode copy parameter
    attr_accessor :spushv_klength_warn

    # for GUI tool
    attr_accessor :gui_run_snapshot

    # for log
    attr_accessor :log_shift_size

    def initialize
      @config_path = nil
      @pid_file = nil
      @run_recover = false
      @run_sync_routing = false
      @run_iterate_storage = false
      @run_storage_clean_up = false
      @run_receive_a_vnode = {}
      @run_release = false
      @run_join = false
      @run_balance = false
      @gui_run_snapshot = false
      @gui_run_gather_logs = false
      @last_clean_up = Time.now
      @gui_last_snapshot = []
      @spushv_protection = false
      @stream_copy_wait = 0.0001
      @stream_show_wait = 0.001
      @dcnice = 3
      @clean_up_interval = 300
      @enabled_vnodes_balance = nil
      @write_count = 0
      @read_count = 0
      @delete_count = 0
      @out_count = 0
      @out_message_count = 0
      @redundant_count = 0
      @compression_threshold = 0
      @hilatency_warn_time = 5.0
      @wb_command_map = {}
      @latency_log = false
      @latency_check_cmd = %w(get set delete)
      @latency_check_time_count = false
      reset_latency_data
      @spushv_klength_warn = 1024 # 1kB
      @spushv_vlength_warn = 1024 * 1024 # 1MB
      @spushv_read_timeout = 100
      @reqpushv_timeout_count = 300 # 0.1 * 300 sec
      @routing_transaction_timeout = 3600 * 3 # 3hr
      @log_shift_size = 1_048_576
      @log_shift_age = 0
      @log_level = :debug
    end

    def my_node_id
      "#{@address}_#{port}"
    end

    def stat
      ret = {}
      ret['stats.config_path'] = @config_path
      ret['stats.pid_file'] = @pid_file
      ret['stats.address'] = @address
      ret['stats.port'] = @port
      ret['stats.daemon'] = @daemon
      ret['stats.name'] = @name
      ret['stats.verbose'] = @verbose
      ret['stats.replication_in_host'] = replication_in_host
      ret['stats.run_recover'] = @run_recover
      ret['stats.run_sync_routing'] = @run_sync_routing
      ret['stats.run_iterate_storage'] = @run_iterate_storage
      ret['stats.run_storage_clean_up'] = @run_storage_clean_up
      ret['stats.run_receive_a_vnode'] = @run_receive_a_vnode.inspect
      ret['stats.run_release'] = @run_release
      ret['stats.run_join'] = @run_join
      ret['stats.run_balance'] = @run_balance
      ret['stats.gui_run_snapshot'] = @gui_run_snapshot
      ret['stats.last_clean_up'] = @last_clean_up
      ret['stats.gui_last_snapshot'] = @gui_last_snapshot
      ret['stats.spushv_protection'] = @spushv_protection
      ret['stats.stream_copy_wait'] = @stream_copy_wait
      ret['stats.stream_show_wait'] = @stream_show_wait
      ret['stats.dcnice'] = @dcnice
      ret['stats.clean_up_interval'] = @clean_up_interval
      ret['stats.compression_threshold'] = @compression_threshold
      ret['stats.write_count'] = @write_count
      ret['stats.read_count'] = @read_count
      ret['stats.delete_count'] = @delete_count
      ret['stats.out_count'] = @out_count
      ret['stats.out_message_count'] = @out_message_count
      ret['stats.redundant_count'] = @redundant_count
      ret['stats.hilatency_warn_time'] = @hilatency_warn_time
      ret['stats.wb_command_map'] = @wb_command_map.inspect
      ret['stats.latency_log'] = @latency_log
      ret['stats.latency_check_cmd'] = @latency_check_cmd
      ret['stats.latency_check_time_count'] = @latency_check_time_count
      ret['stats.spushv_klength_warn'] = @spushv_klength_warn
      ret['stats.spushv_vlength_warn'] = @spushv_vlength_warn
      ret['stats.spushv_read_timeout'] = @spushv_read_timeout
      ret['stats.reqpushv_timeout_count'] = @reqpushv_timeout_count
      ret['stats.routing_transaction_timeout'] = @routing_transaction_timeout
      ret['stats.log_shift_size'] = @log_shift_size
      ret['stats.log_shift_age'] = @log_shift_age
      ret['stats.log_level'] = @log_level
      ret
    end

    def clear_counters
      clear_count(:@write_count)
      clear_count(:@read_count)
      clear_count(:@delete_count)
      clear_count(:@out_count)
      clear_count(:@out_message_count)
      clear_count(:@redundant_count)
    end

    def do_clean_up?
      @last_clean_up.to_i + @clean_up_interval < Time.now.to_i
    end

    # Starts the latency check of the commands +cmds+, which logs their
    # average every +time_count+ seconds, over again.
    def start_latency_check(cmds, time_count)
      @latency_check_cmd = cmds
      @latency_check_time_count = time_count
      @latency_log = true
      reset_latency_data
    end

    def stop_latency_check
      @latency_check_cmd = []
      @latency_check_time_count = false
      @latency_log = false
      reset_latency_data
    end

    def watch_latency(cmds)
      @latency_check_cmd.concat(cmds)
    end

    def unwatch_latency(cmds)
      cmds.each do |cmd|
        @latency_check_cmd.delete(cmd)
        @latency_data.delete(cmd)
      end
    end

    # Logs the averages every +time_count+ seconds, or stops the check if nil.
    def latency_time_count=(time_count)
      @latency_check_time_count = time_count || false
      @latency_log = !time_count.nil?
    end

    # Records +latency+, the seconds that +cmd+ took, in latency_data: the
    # last 10 latencies, the maximum and the minimum. Every
    # latency_check_time_count seconds, logs their average and starts over.
    # The handler calls it while latency_log is on.
    def record_latency(cmd, latency)
      data = @latency_data[cmd]
      if data.empty?
        data['latency'] = []
        data['latency_max'] = { 'current' => 0 }
        data['latency_min'] = { 'current' => 99_999 }
        data['time'] = Time.now.to_i
      end
      data['latency'].shift if data['latency'].length >= 10
      data['latency'] << latency
      data['latency_max']['current'] = latency if latency > data['latency_max']['current']
      data['latency_min']['current'] = latency if latency < data['latency_min']['current']
      return unless @latency_check_time_count && Time.now.to_i - data['time'] > @latency_check_time_count

      log_latency(cmd, data)
      data['time'] = Time.now.to_i
      data['latency_past'] = data['latency']
      data['latency'] = []
      %w(latency_max latency_min).each { |k| data[k]['past'] = data[k]['current'] }
      data['latency_max']['current'] = 0
      data['latency_min']['current'] = 99_999
    end

    private

    def reset_latency_data
      @latency_data = Hash.new { |hash, key| hash[key] = {} }
    end

    def log_latency(cmd, data)
      average = data['latency'].sum(0.0) / data['latency'].size
      Logging::RLogger.instance.debug(
        "Latency average[#{cmd}]: #{format('%.8f', average)}" \
        "(denominator=#{data['latency'].length} " \
        "max=#{format('%.8f', data['latency_max']['current'])} " \
        "min=#{format('%.8f', data['latency_min']['current'])})"
      )
    end

    def clear_count(var)
      return unless instance_variable_get(var) > 0xffffffff

      instance_variable_set(var, 0)
    end
  end
end
