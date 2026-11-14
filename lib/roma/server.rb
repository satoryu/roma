require 'optparse'
require 'roma/version'
require 'roma/configuration'
require 'roma/stats'
require 'roma/command_plugin'
require 'roma/async_event'
require 'roma/peer_command'
require 'roma/cluster_maintenance'
require 'roma/pid_file'
require 'roma/write_behind'
require 'roma/logging/rlogger'
require 'roma/command/receiver'
require 'roma/messaging/connection_pool'
require 'roma/event/em_connection_pool'
require 'roma/routing/churnbased_routing_table'
require 'timeout'
require 'roma/tcp_fast_fallback'

module Roma
  # A ROMA node: it listens for the commands, keeps the data in its storages
  # and works with the other nodes. roma server runs it.
  class Server
    include AsyncEvent
    include WriteBehind::Process
    include PeerCommand
    include ClusterMaintenance

    # +argv+ is the arguments of roma server, such as ["localhost", "-p",
    # "11211", "-d"]. +program+ is the name in the usage. With -d, the server
    # runs as a daemon.
    def self.run(argv, program: 'roma server')
      $roma = new(argv, program: program)
      if $roma.daemon?
        daemonize { $roma.start }
      else
        $roma.start
      end
    end

    # Runs the block in a child process of a new session, and exits. The pid
    # of the child is written to the standard error. Until the server traps
    # them to stop, INT, TERM and HUP make the child exit at once.
    def self.daemonize
      pid = Process.fork do
        Process.setsid
        %i(INT TERM HUP).each { |sig| Signal.trap(sig) { exit! 0 } }
        File.open(File::NULL, 'r+') do |null|
          [$stdin, $stdout, $stderr].each { |io| io.reopen(null) }
        end
        yield
      end
      warn pid
      exit! 0
    end

    # The config file that the server loads without --config, in the
    # current directory.
    DEFAULT_CONFIG = 'config.rb'.freeze
    # Seconds that any regexp may take on a string in the server.
    REGEXP_TIMEOUT = 1.0

    attr_reader :storages, :routing_table, :stats, :wb_writer, :cluster_replication_writer

    attr_accessor :eventloop, :startup

    # +program+ is the name in the usage.
    def initialize(argv = nil, program: 'roma server')
      @stats = Roma::Stats.instance
      @startup = true
      @program = program
      options(argv)
      check_pid_file
      initialize_stats
      initialize_connection
      initialize_logger
      @log.info("The config file: #{@stats.config_path || 'none, with the defaults'}")
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

      pid_file&.write
      # A regexp that a client gives, such as that of set_cleanup_regexp,
      # can't take a thread for long.
      Regexp.timeout = REGEXP_TIMEOUT
      @storages.each do |_hashname, st|
        st.opendb
      end

      start_async_event_loop
      start_write_behind_process
      start_periodic_jobs

      AsyncEvent.queue.push(AsyncMessage.new('start_join_process')) if @stats.join_node_id

      # select a kind of system call
      if Roma.config.connection.use_epoll
        @log.info('use an epoll')
        EM.epoll
        EM.set_descriptor_table_size(Roma.config.connection.descriptor_table_size)
      else
        @log.info('use a select')
      end

      address = bind_address
      @eventloop = true
      while @eventloop
        @eventloop = false
        begin
          # initialize an instance of connections as restarting of an evantmachine
          Event::Handler.connections.each_key do |k|
            k.close_connection
          rescue Exception => e
            @log.error("#{e}\n#{$@}")
          end
          Event::Handler.connections.clear

          EventMachine.run do
            trap_stop_signals
            EventMachine.start_server(address, @stats.port,
                                      Roma::Command::Receiver,
                                      @storages, @routing_table)
            # a management of connections lives
            EventMachine.add_periodic_timer(10) do
              if Event::Handler.connection_expire_time > 0
                dellist = []
                Event::Handler.connections.each do |k, _v|
                  if k.connected == false || k.last_access.nil?
                    dellist << k
                  elsif k.last_access < Time.now - Event::Handler.connection_expire_time
                    begin
                      k.close_connection
                      if k.addr
                        @log.info("connection expired from #{k.addr}:#{k.port},lastcmd = #{k.lastcmd}")
                      else
                        @log.info('connection expired in irregular connection')
                        dellist << k
                      end
                    rescue Exception => e
                      @log.error("#{e}\n#{$@}")
                      dellist << k
                    end
                  end
                end
                dellist.each do |k|
                  @log.info("delete connection lastcmd = #{k.lastcmd}")
                  Event::Handler.connections.delete(k)
                end
              end
            end

            @log.info("Now accepting connections on address #{address}, port #{@stats.port}")
          end
        rescue SignalException => e
          if daemon?
            @log.error("#{e.inspect}\n#{$@}")
            retry
          else
            warn "#{e.inspect}"
          end
        rescue Exception => e
          @log.error("#{e}\n#{$@}")
          @log.error('restart an eventmachine')
          retry
        end
      end
      # Another signal stops the server at once, if stopping takes long.
      %i(INT TERM HUP).each { |sig| Signal.trap(sig, 'DEFAULT') }
      stop_async_event_loop
      stop_write_behind_process
      stop
    ensure
      pid_file&.remove
    end

    def daemon? = @stats.daemon

    # Stops the event loop by INT, TERM and HUP. Raised as an error, the
    # signal could come while a request is handled, where the error is
    # rescued and logged, and the server wouldn't stop.
    def trap_stop_signals
      %i(INT TERM HUP).each do |sig|
        Signal.trap(sig) do
          @eventloop = false
          EventMachine.stop_event_loop
        end
      end
    end

    # Stops cleaning up the storages, and waits for it up to +timeout+
    # seconds. Returns false if it didn't stop by then, such as when it waits
    # for a node that hangs.
    def stop_clean_up(timeout: Roma.config.connection.pool.timeout) # rubocop:disable Naming/PredicateMethod
      @stats.last_clean_up = Time.now
      return true unless @stats.run_storage_clean_up

      @log.info('Storage clean up process will be stop.')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while @stats.run_storage_clean_up
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        @storages.each_value { |st| st.stop_clean_up }
        sleep 0.005
      end
      true
    end

    private

    # The address that the server listens on: config.bind_address, or the
    # IPv4 address of the host of this node, since the other nodes connect
    # to it by IPv4.
    def bind_address
      Roma.config.bind_address ||
        Addrinfo.getaddrinfo(@stats.address, nil, :INET, :STREAM).first.ip_address
    end

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
      unless Event::Handler.update_continuous_limit(connection.continuous_limit)
        raise 'config parse error : connection.continuous_limit'
      end

      Event::Handler.connection_expire_time = connection.expire_time
      Messaging::ConnectionPool.instance.expire_time = connection.pool.expire_time
      Messaging::ConnectionPool.instance.maxlength = connection.pool.max
      Messaging::ConnectionPool.instance.timeout = connection.pool.timeout
      Event::EMConnectionPool.instance.expire_time = connection.event_machine_pool.expire_time
      Event::EMConnectionPool.instance.maxlength = connection.event_machine_pool.max
      Event::EMConnectionPool.instance.timeout = connection.event_machine_pool.timeout
    end

    def initialize_wb_writer
      @wb_writer = Roma::WriteBehind::FileWriter.new(
        Roma.config.write_behind.path,
        Roma.config.write_behind.shift_size,
        @log,
        node_id: @stats.my_node_id
      )

      @cluster_replication_writer = Roma::WriteBehind::StreamWriter.new(@log)
    end

    def initialize_plugin
      Roma::CommandPlugin.require_all(Roma.config.command_plugin_path).each do |path|
        @log.info("#{path} loaded")
      end
      Roma::CommandPlugin.plugins.each do |plugin|
        Roma::Command::Receiver.class_eval do
          include plugin
        end
        @log.info("#{plugin} included")
      end

      return unless @stats.command_protection_disabled

      Command::Receiver.make_event_list
    end

    def initialize_handler
      if @stats.verbose
        Event::Handler.class_eval do
          alias gets2 gets
          undef gets

          def gets
            ret = gets2
            @log.info("command log:#{ret.chomp}") if ret
            ret
          end
        end
      end

      if @stats.join_node_id
        Command::Receiver.make_event_list
      else
        Command::Receiver.make_starting_event_list
      end
    end

    def initialize_logger
      log = Roma.config.log
      Roma::Logging::RLogger.create_singleton_instance("#{log.path}/#{@stats.my_node_id}.log",
                                                       log.shift_age,
                                                       log.shift_size)
      @log = Roma::Logging::RLogger.instance
      @log.level = Roma::Logging::RLogger::Severity::LEVELS.fetch(log.level)
    end

    def options(argv)
      opts = OptionParser.new
      opts.banner = "usage:#{@program} [options] address"

      @stats.daemon = false
      opts.on('-d', '--daemon') { |_v| @stats.daemon = true }

      opts.on_tail('-h', '--help', 'Show this message') do
        puts opts
        exit
      end

      opts.on('-j', '--join [address:port]') { |v| @stats.join_node_id = v }

      opts.on('-p', '--port [PORT]') { |v| @stats.port = v }

      @stats.verbose = false
      opts.on(nil, '--verbose') { |_v| @stats.verbose = true }

      opts.on_tail('-v', '--version', 'Show version') do
        puts "#{@program} #{Roma::VERSION}"
        exit
      end

      opts.on('-n', '--name [name]') { |v| @stats.name = v }

      # OptionParser takes --replication_in_host too.
      @stats.replication_in_host = false
      opts.on(nil, '--replication-in-host', 'Allow redundancy to same host') do
        @stats.replication_in_host = true
      end

      @stats.command_protection_disabled = false
      opts.on(nil, '--disable-command-protection', 'Command protection disable while starting') do
        @stats.command_protection_disabled = true
      end

      opts.on('--config FILE', "Load the config file (default: #{DEFAULT_CONFIG} if it exists)") do |v|
        @stats.config_path = File.expand_path(v)
      end

      opts.on('--pid-file PATH', 'Write the pid to the file, and remove it when the server stops') do |v|
        @stats.pid_file = File.expand_path(v)
      end

      opts.parse!(argv)
      raise OptionParser::ParseError.new if argv.length < 1

      @stats.address = argv[0]

      # Without --config and config.rb, the settings are the defaults, or
      # what is set in Roma.configure before.
      @stats.config_path ||= File.expand_path(DEFAULT_CONFIG) if File.file?(DEFAULT_CONFIG)
      Roma.load_config(@stats.config_path) if @stats.config_path

      @stats.name = Roma.config.name unless @stats.name
      @stats.port = Roma.config.port.to_s unless @stats.port
      @stats.pid_file ||= File.expand_path(Roma.config.pid_file) if Roma.config.pid_file

      raise OptionParser::ParseError.new('Port number is not numeric.') unless @stats.port =~ /^\d+$/

      @stats.join_node_id.sub!(':', '_') if @stats.join_node_id
      if @stats.join_node_id && !(@stats.join_node_id =~ /^.+_\d+$/)
        raise OptionParser::ParseError.new('[address:port] can not parse.')
      end
    rescue OptionParser::ParseError => e
      warn e.message
      warn opts.help
      exit 1
    rescue Configuration::Error => e
      warn e.message
      exit 1
    end

    # Exits if the server can't take the pid file. It runs before -d makes
    # the daemon, to tell the error on the standard error.
    def check_pid_file
      error = pid_file&.error
      return unless error

      warn error
      exit 1
    end

    def pid_file
      @stats.pid_file && PidFile.new(@stats.pid_file)
    end

    def initialize_storages
      @storages = {}
      storage = Roma.config.storage
      path = "#{storage.path}/#{@stats.my_node_id}"
      hash_names = Dir.glob("#{path}/*").select { |f| File.directory?(f) }.map { |f| File.basename(f) }
      hash_names = ['roma'] if hash_names.empty?
      hash_names.each do |hash_name|
        @storages[hash_name] = storage.build("#{path}/#{hash_name}", @routing_table.vnodes)
      end
    end

    def initialize_rttable
      routing = Roma.config.routing
      if @stats.join_node_id
        initialize_rttable_join
      else
        fname = File.join(routing.path, Roma::Routing::RoutingData.file_name(@stats.my_node_id))
        raise "#{fname} not found." unless File.exist?(fname)

        routing_data = Roma::Routing::RoutingData.load(fname)
        raise 'It failed in loading the routing table data.' unless routing_data

        @routing_table = routing_table_class.new(routing_data, fname)
      end

      @routing_table.node_id_substitutions = routing.node_id_substitutions
      @routing_table.failure_count_threshold = routing.failure_count_threshold
      @routing_table.failure_count_gap = routing.failure_count_gap
      @routing_table.lost_action = routing.lost_action
      @routing_table.auto_recover = routing.auto_recover

      @routing_table.enabled_failover = false
      @routing_table.on_leave do |node_id|
        Roma::Messaging::ConnectionPool.instance.close_same_host(node_id)
        Roma::Event::EMConnectionPool.instance.close_same_host(node_id)
        Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('broadcast_cmd',
                                                           ["leave #{node_id}", [@stats.my_node_id, node_id, 5]]))
      end
      @routing_table.on_lost do
        if @routing_table.lost_action == :shutdown
          async_broadcast_cmd("rbalse lose_data\r\n")
          EventMachine.stop_event_loop
          @log.error('The server has stopped, so that lose data.')
        end
      end
      @routing_table.on_recover do |action|
        if %i(shutdown auto_assign).include?(@routing_table.lost_action) && @routing_table.auto_recover == true
          Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new("#{action}"))
        else
          @log.error("AUTO_RECOVER is off or Unavailable value is set to [DEFAULT_LOST_ACTION] => #{@routing_table.lost_action}")
        end
      end

      @routing_table.event_limit_line = routing.event_limit_line
      Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_get_routing_event'))
    end

    def initialize_rttable_join
      name = async_send_cmd(@stats.join_node_id, "whoami\r\n")
      raise "No respons from #{@stats.join_node_id}." unless name

      if name != @stats.name
        raise "#{@stats.join_node_id} has diffarent name.\n" +
              "me = \"#{@stats.name}\"  #{@stats.join_node_id} = \"#{name}\""
      end

      fname = File.join(Roma.config.routing.path, Roma::Routing::RoutingData.file_name(@stats.my_node_id))
      unless routing_data = fetch_routedump(@stats.join_node_id)
        raise "It failed in getting the routing table data from #{@stats.join_node_id}."
      end

      routing_data.save(fname)

      raise "ROMA has already contained #{@stats.my_node_id}." if routing_data.nodes.include?(@stats.my_node_id)

      @routing_table = routing_table_class.new(routing_data, fname)
      nodes = @routing_table.nodes

      nodes.each do |node_id|
        con = Roma::Messaging::ConnectionPool.instance.checkout(node_id)
        con.write("join #{@stats.my_node_id}\r\n")
        raise "Hotscale initialize failed.\n#{node_id} is busy." if con.gets != "ADDED\r\n"

        Roma::Messaging::ConnectionPool.instance.checkin(node_id, con)
      rescue StandardError
        raise "Hotscale initialize failed.\n#{node_id} unreachable connection."
      end
      @routing_table.add_node(@stats.my_node_id)
    end

    def routing_table_class
      Roma.config.routing.table_class || Roma::Routing::ChurnbasedRoutingTable
    end

    def stop
      @storages.each_value do |st|
        st.closedb
      end
      @routing_table.close_log
      @log.info("The server has stopped: #{@stats.my_node_id}")
    end
  end
end
