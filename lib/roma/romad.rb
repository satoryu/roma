#!/usr/bin/env ruby
require 'optparse'
require 'roma/version'
require 'roma/configuration'
require 'roma/stats'
require 'roma/command_plugin'
require 'roma/async_process'
require 'roma/write_behind'
require 'roma/logging/rlogger'
require 'roma/command/receiver'
require 'roma/messaging/con_pool'
require 'roma/event/em_con_pool'
require 'roma/routing/churnbased_routing_table'
require 'timeout'
require 'roma/tcp_fast_fallback'

module Roma

  class Romad
    include AsyncProcess
    include WriteBehindProcess

    attr :storages
    attr :routing_table
    attr :stats
    attr :wb_writer
    attr :cluster_replication_writer

    attr_accessor :eventloop
    attr_accessor :startup

    # +program+ is the name in the usage.
    def initialize(argv = nil, program: File.basename($0))
      @stats = Roma::Stats.instance
      @startup = true
      @program = program
      options(argv)
      initialize_stats
      initialize_connection
      initialize_logger
      initialize_rttable
      initialize_storages
      initialize_handler
      initialize_plugin
      initialize_wb_writer
    end

    def start
      if node_check(@stats.my_node_id)
        @log.error("#{@stats.my_node_id} is already running.")
        return
      end

      @storages.each{|hashname,st|
        st.opendb
      }

      start_async_process
      start_wb_process
      timer

      if @stats.join_node_id
        AsyncProcess::queue.push(AsyncMessage.new('start_join_process'))
      end

      # select a kind of system call
      if Roma.config.connection.use_epoll
        @log.info("use an epoll")
        EM.epoll
        EM.set_descriptor_table_size(Roma.config.connection.descriptor_table_size)
      else
        @log.info("use a select")
      end

      @eventloop = true
      while(@eventloop)
        @eventloop = false
        begin
          # initialize an instance of connections as restarting of an evantmachine
          Event::Handler::connections.each_key{|k|
            begin
              k.close_connection
            rescue Exception => e
              @log.error("#{e}\n#{$@}")
            end
          }
          Event::Handler::connections.clear

          EventMachine::run do
            trap_stop_signals
            EventMachine.start_server('0.0.0.0', @stats.port,
                                      Roma::Command::Receiver,
                                      @storages, @routing_table)
            # a management of connections lives
            EventMachine::add_periodic_timer( 10 ) {
              if Event::Handler::connection_expire_time > 0
                dellist = []
                Event::Handler::connections.each{|k,v|
                  if k.connected == false || k.last_access == nil
                    dellist << k
                  elsif k.last_access < Time.now - Event::Handler::connection_expire_time
                    begin
                      k.close_connection
                      if k.addr
                        @log.info("connection expired from #{k.addr}:#{k.port},lastcmd = #{k.lastcmd}")
                      else
                        @log.info("connection expired in irregular connection")
                        dellist << k
                      end
                    rescue Exception => e
                      @log.error("#{e}\n#{$@}")
                      dellist << k
                    end
                  end
                }
                dellist.each{|k|
                  @log.info("delete connection lastcmd = #{k.lastcmd}")
                  Event::Handler::connections.delete(k)
                }
              end
            }

            @log.info("Now accepting connections on address #{@stats.address}, port #{@stats.port}")
          end
        rescue SignalException => e
          if daemon?
            @log.error("#{e.inspect}\n#{$@}")
            retry
          else
            $stderr.puts "#{e.inspect}"
          end
        rescue Exception => e
          @log.error("#{e}\n#{$@}")
          @log.error("restart an eventmachine")
          retry
        end
      end
      # Another signal stops romad at once, if stopping takes long.
      %i(INT TERM HUP).each { |sig| Signal.trap(sig, 'DEFAULT') }
      stop_async_process
      stop_wb_process
      stop
    end

    def daemon?; @stats.daemon; end

    # Stops the event loop by INT, TERM and HUP. Raised as an error, the
    # signal could come while a request is handled, where the error is
    # rescued and logged, and romad wouldn't stop.
    def trap_stop_signals
      %i(INT TERM HUP).each do |sig|
        Signal.trap(sig) do
          @eventloop = false
          EventMachine::stop_event_loop
        end
      end
    end

    def stop_clean_up
      @stats.last_clean_up = Time.now
      while(@stats.run_storage_clean_up)
        @log.info("Storage clean up process will be stop.")
        @storages.each_value{|st| st.stop_clean_up}
        sleep 0.005
      end
    end

    private

    def initialize_stats
      config = Roma.config
      @stats.compression_threshold = config.redundant.compression_threshold
      @stats.stream_copy_wait = config.data_copy.stream_copy_wait
      @stats.stream_show_wait = config.log.stream_show_wait
      @stats.wb_command_map = config.write_behind.command_map
      @stats.clean_up_interval = config.storage.clean_up_interval
      @stats.log_shift_size = config.log.shift_size
      @stats.log_shift_age = config.log.shift_age
      @stats.log_level = config.log.level
    end

    def initialize_connection
      connection = Roma.config.connection
      unless Event::Handler.set_continuous_limit(connection.continuous_limit)
        raise "config parse error : connection.continuous_limit"
      end
      Event::Handler::connection_expire_time = connection.expire_time
      Messaging::ConPool.instance.expire_time = connection.pool.expire_time
      Messaging::ConPool.instance.maxlength = connection.pool.max
      Event::EMConPool::instance.expire_time = connection.event_machine_pool.expire_time
      Event::EMConPool::instance.maxlength = connection.event_machine_pool.max
    end

    def initialize_wb_writer
      @wb_writer = Roma::WriteBehind::FileWriter.new(
                                                     Roma.config.write_behind.path,
                                                     Roma.config.write_behind.shift_size,
                                                     @log)

      @cluster_replication_writer = Roma::WriteBehind::StreamWriter.new(@log)
    end

    def initialize_plugin
      Roma.config.plugins.each do|f|
        path = plugin_path(f)
        require path
        @log.info("#{path} loaded")
      end
      Roma::CommandPlugin.plugins.each do|plugin|
          Roma::Command::Receiver.class_eval do
            include plugin
          end
          @log.info("#{plugin.to_s} included")
      end

      if @stats.command_protection_disabled
        Command::Receiver::make_event_list
      end
    end

    # The plugins of ROMA are in roma/command_plugin. Other plugins may be in
    # roma/plugin, where they were before.
    def plugin_path(file)
      path = "roma/command_plugin/#{file}"
      $LOAD_PATH.resolve_feature_path(path) ? path : "roma/plugin/#{file}"
    end

    def initialize_handler
      if @stats.verbose
        Event::Handler.class_eval{
          alias gets2 gets
          undef gets

          def gets
            ret = gets2
            @log.info("command log:#{ret.chomp}") if ret
            ret
          end
        }
      end

      if @stats.join_node_id
        Command::Receiver::make_event_list
      else
        Command::Receiver::make_starting_event_list
      end
    end

    def initialize_logger
      log = Roma.config.log
      Roma::Logging::RLogger.create_singleton_instance("#{log.path}/#{@stats.my_node_id}.log",
                                                       log.shift_age,
                                                       log.shift_size)
      @log = Roma::Logging::RLogger.instance

      case log.level
      when :debug
        @log.level = Roma::Logging::RLogger::Severity::DEBUG
      when :info
        @log.level = Roma::Logging::RLogger::Severity::INFO
      when :warn
        @log.level = Roma::Logging::RLogger::Severity::WARN
      when :error
        @log.level = Roma::Logging::RLogger::Severity::ERROR
      end
    end

    def options(argv)
      opts = OptionParser.new
      opts.banner="usage:#{@program} [options] address"

      @stats.daemon = false
      opts.on("-d","--daemon") { |v| @stats.daemon = true }

      opts.on_tail("-h", "--help", "Show this message") {
        puts opts; exit
      }

      opts.on("-j","--join [address:port]") { |v| @stats.join_node_id = v }

      opts.on("-p", "--port [PORT]") { |v| @stats.port = v }

      @stats.verbose = false
      opts.on(nil,"--verbose"){ |v| @stats.verbose = true }

      opts.on_tail("-v", "--version", "Show version") {
        puts "romad.rb #{Roma::VERSION}"; exit
      }

      opts.on("-n", "--name [name]") { |v| @stats.name = v }

      # OptionParser takes --replication_in_host too.
      @stats.replication_in_host = false
      opts.on(nil,"--replication-in-host", "Allow redundancy to same host"){
        @stats.replication_in_host = true
      }

      @stats.command_protection_disabled = false
      opts.on(nil,"--disable-command-protection", "Command protection disable while starting"){
        @stats.command_protection_disabled = true
      }

      opts.on("--config [file path of the config.rb]"){ |v| @stats.config_path = File.expand_path(v) }

      opts.parse!(argv)
      raise OptionParser::ParseError.new if argv.length < 1
      @stats.address = argv[0]

      # Without --config, the settings are the defaults, or what is set in
      # Roma.configure before.
      Roma.load_config(@stats.config_path) if @stats.config_path

      @stats.name = Roma.config.name unless @stats.name
      @stats.port = Roma.config.port.to_s unless @stats.port

      unless @stats.port =~ /^\d+$/
        raise OptionParser::ParseError.new('Port number is not numeric.')
      end

      @stats.join_node_id.sub!(':','_') if @stats.join_node_id
      if @stats.join_node_id && !(@stats.join_node_id =~ /^.+_\d+$/)
        raise OptionParser::ParseError.new('[address:port] can not parse.')
      end
    rescue OptionParser::ParseError => e
      $stderr.puts e.message
      $stderr.puts opts.help
      exit 1
    rescue Configuration::Error => e
      $stderr.puts e.message
      exit 1
    end

    def initialize_storages
      @storages = {}
      storage = Roma.config.storage
      path = "#{storage.path}/#{@stats.my_node_id}"
      st_class = storage.engine_class
      st_division_count = storage.division_count
      st_option = storage.option
      Dir.glob("#{path}/*").each{|f|
        if File.directory?(f)
          hash_name = File.basename(f)
          st = st_class.new
          st.storage_path = "#{path}/#{hash_name}"
          st.vn_list = @routing_table.vnodes
          st.st_class = st_class
          st.divnum = st_division_count
          st.option = st_option
          @storages[hash_name] = st
        end
      }
      if @storages.length == 0
        hash_name = 'roma'
        st = st_class.new
        st.storage_path = "#{path}/#{hash_name}"
        st.vn_list = @routing_table.vnodes
        st.st_class = st_class
        st.divnum = st_division_count
        st.option = st_option
        @storages[hash_name] = st
      end
    end

    def initialize_rttable
      routing = Roma.config.routing
      if @stats.join_node_id
        initialize_rttable_join
      else
        fname = File.join(routing.path, Roma::Routing::RoutingData.file_name(@stats.my_node_id))
        raise "#{fname} not found." unless File::exist?(fname)
        routing_data = Roma::Routing::RoutingData::load(fname)
        raise "It failed in loading the routing table data." unless routing_data
        @routing_table = (routing.table_class || Roma::Routing::ChurnbasedRoutingTable).new(routing_data, fname)
      end

      @routing_table.node_id_substitutions = routing.node_id_substitutions
      @routing_table.failure_count_threshold = routing.failure_count_threshold
      @routing_table.failure_count_gap = routing.failure_count_gap
      @routing_table.lost_action = routing.lost_action
      @routing_table.auto_recover = routing.auto_recover

      @routing_table.enabled_failover = false
      @routing_table.set_leave_proc{|node_id|
        Roma::Messaging::ConPool.instance.close_same_host(node_id)
        Roma::Event::EMConPool.instance.close_same_host(node_id)
        Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('broadcast_cmd',["leave #{node_id}",[@stats.my_node_id,node_id,5]]))
      }
      @routing_table.set_lost_proc{
        if @routing_table.lost_action == :shutdown
          async_broadcast_cmd("rbalse lose_data\r\n")
          EventMachine::stop_event_loop
          @log.error("Romad has stopped, so that lose data.")
        end
      }
      @routing_table.set_recover_proc{|action|
        if (@routing_table.lost_action == :shutdown || @routing_table.lost_action == :auto_assign) && @routing_table.auto_recover == true
          Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new("#{action}"))
        else
          @log.error("AUTO_RECOVER is off or Unavailable value is set to [DEFAULT_LOST_ACTION] => #{@routing_table.lost_action}")
        end
      }

      @routing_table.event_limit_line = routing.event_limit_line
      Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_get_routing_event'))
    end

    def initialize_rttable_join
      name = async_send_cmd(@stats.join_node_id,"whoami\r\n")
      unless name
        raise "No respons from #{@stats.join_node_id}."
      end

      if name != @stats.name
        raise "#{@stats.join_node_id} has diffarent name.\n" +
          "me = \"#{@stats.name}\"  #{@stats.join_node_id} = \"#{name}\""
      end

      fname = File.join(Roma.config.routing.path, Roma::Routing::RoutingData.file_name(@stats.my_node_id))
      if routing_data = get_routedump(@stats.join_node_id)
        routing_data.save(fname)
      else
        raise "It failed in getting the routing table data from #{@stats.join_node_id}."
      end

      if routing_data.nodes.include?(@stats.my_node_id)
        raise "ROMA has already contained #{@stats.my_node_id}."
      end

      @routing_table = Roma::Routing::ChurnbasedRoutingTable.new(routing_data,fname)
      nodes = @routing_table.nodes

      nodes.each{|node_id|
        begin
          con = Roma::Messaging::ConPool.instance.get_connection(node_id)
          con.write("join #{@stats.my_node_id}\r\n")
          if con.gets != "ADDED\r\n"
            raise "Hotscale initialize failed.\n#{node_id} is busy."
          end
          Roma::Messaging::ConPool.instance.return_connection(node_id, con)
        rescue
          raise "Hotscale initialize failed.\n#{node_id} unreachable connection."
        end
      }
      @routing_table.add_node(@stats.my_node_id)
    end

    def get_routedump(node_id)
      received = receive_routing_dump(node_id, "routingdump bin\r\n")
      unless received
        received = receive_routing_dump(node_id, "routingdump\r\n")
        routing_data = Marshal.load(received)
      else
        routing_data = Routing::RoutingData.decode_binary(received)
      end
      routing_data
    rescue
      nil
    end

    def receive_routing_dump(node_id, cmd)
      con = Messaging::ConPool.instance.get_connection(node_id)
      con.write(cmd)
      unless select [con], nil, nil, 1
        con.close
        return nil
      end
      len = con.gets
      if len.to_i <= 0
        con.close
        return nil
      end

      received=''
      while(received.length != len.to_i)
        received = received + con.read(len.to_i - received.length)
      end
      con.read(2)
      con.gets
      Messaging::ConPool.instance.return_connection(node_id,con)
      received
    rescue Exception
      nil
    end

    def timer
      t = Thread.new do
        loop do
          sleep 1
          timer_event_1sec
        end
      end
      t[:name] = 'timer_1sec'
      t = Thread.new do
        loop do
          sleep 10
          timer_event_10sec
        end
      end
      t[:name] = 'timer_10sec'
    end

    def timer_event_1sec
      if @routing_table.enabled_failover
        nodes=@routing_table.nodes
        nodes.delete(@stats.my_node_id)
        nodes_check(nodes)
      end

      if (@stats.run_join || @stats.run_recover || @stats.run_balance) &&
          @stats.run_storage_clean_up
        stop_clean_up
      end
    rescue Exception =>e
      @log.error("#{e}\n#{$@}")
    end

    def timer_event_10sec
      if @startup && @routing_table.enabled_failover == false
        @log.debug("nodes_check start")
        nodes=@routing_table.nodes
        nodes.delete(@stats.my_node_id)
        if nodes_check(nodes)
          @log.info("all nodes started")
          AsyncProcess::queue.clear
          @routing_table.enabled_failover = true
          Command::Receiver::make_event_list
          @startup = false
        end
      elsif @routing_table.enabled_failover == false
        @log.warn("failover disable now!!")
      else
        version_check
        @routing_table.delete_old_transactions(@stats.routing_transaction_timeout)
        start_sync_routing_process
      end

      if (@routing_table.enabled_failover &&
          @stats.run_storage_clean_up == false &&
          @stats.run_balance == false &&
          @stats.run_recover == false &&
          @stats.run_iterate_storage == false &&
          @stats.run_join == false &&
          @stats.run_receive_a_vnode.empty? &&
          @stats.do_clean_up?)
        Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_storage_clean_up_process'))
      end

      if @cluster_replication_writer.run_replication
        if @cluster_replication_writer.change_mklhash?
          node_id = @cluster_replication_writer.replica_nodelist.sample
          @cluster_replication_writer.update_mklhash(node_id)
          @cluster_replication_writer.update_nodelist(node_id)
          @cluster_replication_writer.update_rttable(node_id)
        end
      end

      @stats.clear_counters
    rescue Exception =>e
      @log.error("#{e}\n#{$@}")
    end

    def nodes_check(nodes)
      nodes.each{|node_id|
        return false unless node_check(node_id)
      }
      return true
    end

    def node_check(node_id)
      if @startup && @routing_table.enabled_failover == false
        unless Roma::Messaging::ConPool.instance.check_connection(node_id)
          @log.info("I'm waiting for booting the #{node_id} instance.")
          return false
        end
      end
      name = async_send_cmd(node_id,"whoami\r\n",2)
      return false unless name
      if name != @stats.name
        @log.error("#{node_id} has diffarent name.")
        @log.error("me = \"#{@stats.name}\"  #{node_id} = \"#{name}\"")
        return false
      end
      return true
    end

    def version_check
      nodes=@routing_table.nodes
      nodes.each{|node_id|
        vs = async_send_cmd(node_id,"version\r\n",2)
        next unless vs
        if /VERSION\s(?:ROMA-)?(\d+)\.(\d+)\.(\d+)/ =~ vs
          ver = ($1.to_i << 16) + ($2.to_i << 8) + $3.to_i
          @routing_table.set_version(node_id, ver)
        end
      }
    end

    def start_sync_routing_process
      return if @stats.run_join || @stats.run_recover || @stats.run_balance || @stats.run_sync_routing

      nodes = @routing_table.nodes
      return if nodes.length == 1 && nodes[0] == @stats.my_node_id

      @stats.run_sync_routing = true

      idx=nodes.index(@stats.my_node_id)
      unless idx
        @log.error("My node-id(=#{@stats.my_node_id}) does not found in the routingtable.")
        EventMachine::stop_event_loop
        return
      end
      t = Thread.new{
        begin
          ret = routing_hash_comparison(nodes[idx-1])
          if ret == :inconsistent
            @log.info("create nodes from routes");

            @routing_table.create_nodes_from_routes
            begin
              con = Roma::Messaging::ConPool.instance.get_connection(nodes[idx-1])
              con.write("create_nodes_from_v_idx\r\n")
              if con.gets == "CREATED\r\n"
                Roma::Messaging::ConPool.instance.return_connection(nodes[idx-1], con)
              else
                @log.error("get busy result in create_nodes_from_v_idx command from #{nodes[idx-1]}.")
                con.close
              end
            rescue Exception =>e
              @log.error("create_nodes_from_v_idx command unreachable to the #{nodes[idx-1]}.")
            end
          end
        rescue Exception =>e
          @log.error("#{e}\n#{$@}")
        end
        @stats.run_sync_routing = false
      }
      t[:name] = 'sync_routing'
    end

    def routing_hash_comparison(node_id,id='0')
      return :skip if @stats.run_join || @stats.run_recover || @stats.run_balance

      h = async_send_cmd(node_id,"mklhash #{id}\r\n")
      if h && h.start_with?("ERROR") == false && @routing_table.merkle_tree.get(id) != h
        if (id.length - 1) == @routing_table.divide_bits
          sync_routing(node_id,id)
        else
          routing_hash_comparison(node_id,"#{id}0")
          routing_hash_comparison(node_id,"#{id}1")
        end
        return :inconsistent
      end
      :consistent
    end

    def sync_routing(node_id,id)
      vnode = @routing_table.merkle_tree.to_vnode(id)
      @log.warn("vnode=#{vnode} inconsistent")

      res = async_send_cmd(node_id,"getroute #{vnode}\r\n")
      return if res == nil || res.start_with?("ERROR")
      clock,*node_ids = res.split(' ')
      clock = @routing_table.set_route(vnode, clock.to_i, node_ids)

      if clock.is_a?(Integer) == false
        clock,node_ids = @routing_table.search_nodes_with_clk(vnode)
        cmd = "setroute #{vnode} #{clock-1}"
        node_ids.each{|other_node_id| cmd << " #{other_node_id}" }
        async_send_cmd(node_id,"#{cmd}\r\n")
      end
    end

    def async_send_cmd(node_id, cmd, tout=nil)
      con = res = nil
      if tout
        Timeout.timeout(tout){
          con = Roma::Messaging::ConPool.instance.get_connection(node_id)
          unless con
            @routing_table.proc_failed(node_id) if @routing_table
            @log.error("#{__FILE__}:#{__LINE__}:#{node_id} connection refused,command is #{cmd}.")
            return nil
          end
          con.write(cmd)
          res = con.gets
        }
      else
        con = Roma::Messaging::ConPool.instance.get_connection(node_id)
        unless con
          @routing_table.proc_failed(node_id) if @routing_table
          @log.error("#{__FILE__}:#{__LINE__}:#{node_id} connection refused,command is #{cmd}.")
          return nil
        end
        con.write(cmd)
        res = con.gets
      end
      if res == nil
        @routing_table.proc_failed(node_id) if @routing_table
        return nil
      elsif res.start_with?("ERROR") == false
        @routing_table.proc_succeed(node_id) if @routing_table
        Roma::Messaging::ConPool.instance.return_connection(node_id, con)
      end
      res.chomp
    rescue Exception => e
      @routing_table.proc_failed(node_id) if @routing_table
      @log.error("#{__FILE__}:#{__LINE__}:#{e} #{$@}")
      @log.error("#{__FILE__}:#{__LINE__}:Send command failed that node-id is #{node_id},command is #{cmd}.")
      nil
    end

    def async_broadcast_cmd(cmd,without_node_ids=nil,tout=nil)
      without_node_ids=[@stats.my_node_id] unless without_node_ids
      res = {}
      @routing_table.nodes.each{ |node_id|
        res[node_id] = async_send_cmd(node_id,cmd,tout) unless without_node_ids.include?(node_id)
      }
      res
    rescue Exception => e
      @log.error("#{e}\n#{$@}")
      nil
    end

    def stop
      @storages.each_value{|st|
        st.closedb
      }
      if @routing_table.instance_of?(Roma::Routing::ChurnbasedRoutingTable)
        @routing_table.close_log
      end
      @log.info("Romad has stopped: #{@stats.my_node_id}")
    end

  end # class Romad
end # module Roma

