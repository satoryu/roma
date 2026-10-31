require 'ipaddr'
require 'rbconfig'
require 'socket'
require 'roma/tools/error'

module Roma
  module Tools
    # Starts romads on a host, and finds the romads on other hosts by UDP
    # multicast, to join their ring.
    #
    # The hosts send each other "update:<reply count>: <hostname> [<port> ...]",
    # and the receiver replies while the count is more than 0.
    class Tribunus
      UDP_PORT = 14329
      MULTICAST_ADDR = '225.0.0.123'.freeze
      HEARTBEAT_SECONDS = 300
      HEARTBEAT_LOOP_INTERVAL = 50
      TIMEOUT_SECONDS = 600
      BIN_DIR = File.expand_path('../../../bin', __dir__)
      ROMAD_OPTIONS = ['--replication_in_host'].freeze

      RomadHost = Struct.new(:hostname, :ports, :updated_at)

      # Makes the ports from a range such as "11211-11213". Raises Error if
      # it has less than 2 ports or more than 100.
      def self.parse_ports(range)
        first, last = range.split('-', 2).map { |port| Integer(port, exception: false) }
        raise Error, "The port range should be like 11211-11213: #{range}" unless first && last
        ports = (first..last).to_a
        raise Error, 'The port range should have 2 ports or more.' if ports.size < 2
        raise Error, 'The port range should have 100 ports or less.' if ports.size > 100
        ports
      end

      attr_reader :remote_servers

      # Starts romads at +ports+ of +hostname+. The options are :udp_port,
      # :multicast_addr, :romad_work_dir, :ruby (the command) and :verbose.
      def initialize(hostname, ports, options = {})
        @multicast_addr = options[:multicast_addr] || MULTICAST_ADDR
        @port = options[:udp_port] || UDP_PORT
        @romad_work_dir = options[:romad_work_dir] || '.'
        @ruby = options[:ruby] || RbConfig.ruby
        @verbose = options[:verbose]
        @local = RomadHost.new(hostname, ports, nil)
        @romads = {} # port => pid
        @remote_servers = {} # ipaddr => RomadHost
        @mutex = Mutex.new
        @threads = []
        log [:initialized, @multicast_addr, @port, @romad_work_dir, @ruby]
      end

      # Makes the routing table of the local romads, and starts them.
      def start_new_ring
        prepare_to_start
        nodes = @local.ports.map { |port| "#{@local.hostname}_#{port}" }
        status = wait(spawn(@ruby, File.join(BIN_DIR, 'roma'), 'mkroute', *nodes, *ROMAD_OPTIONS))
        raise Error, 'Failed to make the routing table.' unless status.success?
        @local.ports.each { |port| spawn_romad(port) }
      end

      # Starts the local romads to join the node at +host+ and +port+.
      def start_join(host, port)
        prepare_to_start
        sleep 0.2
        spawn_romads_join(host, port)
      end

      # Asks the other hosts by multicast, and joins one that answers.
      # Raises Error if none answers.
      def start_discover(wait: 3)
        prepare_to_start
        sleep 0.2
        multicast(update_message(1, initial: true))
        sleep wait
        rhost = choose_rhost
        raise Error, 'No server responded.' unless rhost
        spawn_romads_join(rhost.hostname, rhost.ports.first)
      end

      # Waits for the threads of the UDP server and the heartbeat.
      def join
        @threads.each(&:join)
      end

      # Runs a message from +ipaddr+.
      def run_command(ipaddr, msg)
        return unless (m = /\A(.*?):(\d+):(.*)/m.match(msg))
        receive_update(ipaddr, m[2].to_i, m[3]) if m[1] == 'update'
      end

      def update_message(reply_count, initial: false)
        ports = initial ? [] : @romads.keys
        ["update:#{reply_count}: #{@local.hostname}", *ports].join(' ')
      end

      # Forgets the hosts that haven't sent a message for long, and sends a
      # message to the ones that haven't for a while, or have no romad yet.
      def heartbeat(now = Time.now)
        @mutex.synchronize do
          @remote_servers.delete_if { |_ipaddr, host| host.updated_at + TIMEOUT_SECONDS < now }
          @remote_servers.dup
        end.each do |ipaddr, host|
          if host.updated_at + HEARTBEAT_SECONDS < now
            unicast(ipaddr, update_message(0))
          elsif host.ports.empty?
            unicast(ipaddr, update_message(1))
          end
        end
      end

      # A remote host that has romads.
      def choose_rhost
        @mutex.synchronize { @remote_servers.values.find { |rhost| !rhost.ports.empty? } }
      end

      private

      def log(obj)
        warn(obj.is_a?(String) ? obj : obj.inspect) if @verbose
      end

      def receive_update(ipaddr, reply_count, params)
        hostname, *ports = params.split
        return unless hostname
        @mutex.synchronize { @remote_servers[ipaddr] = RomadHost.new(hostname, ports.map(&:to_i), Time.now) }
        unicast(ipaddr, update_message(reply_count - 1)) if reply_count > 0
      end

      def spawn_romads_join(host, port)
        @local.ports.each { |local_port| spawn_romad(local_port, '-j', "#{host}_#{port}") }
      end

      def spawn_romad(port, *args)
        @romads[port] = spawn(@ruby, File.join(BIN_DIR, 'romad'), *ROMAD_OPTIONS, '-p', port.to_s, @local.hostname, *args)
      end

      def spawn(*cmd)
        Process.spawn(*cmd, chdir: @romad_work_dir)
      end

      def wait(pid)
        Process.wait2(pid)[1]
      end

      # The romads, which don't run as daemons, stop by INT. They restart by
      # the other signals.
      def prepare_to_start
        %i(INT TERM HUP).each do |sig|
          Signal.trap(sig) do
            Process.kill(:INT, *@romads.values) unless @romads.empty?
            exit 1
          end
        end
        @threads << Thread.new { server_loop }
        @threads << Thread.new { heartbeat_loop }
      end

      def server_loop
        sock = UDPSocket.new
        sock.bind('0.0.0.0', @port)
        sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP,
                        IPAddr.new(@multicast_addr).hton + IPAddr.new('0.0.0.0').hton)
        log 'start_listen'
        Socket.udp_server_loop_on([sock]) do |msg, src|
          log [:received, msg, src]
          ipaddr = src.remote_address.ip_address
          run_command(ipaddr, msg) if from_remote?(ipaddr)
        end
      end

      def heartbeat_loop
        loop do
          heartbeat
          sleep HEARTBEAT_LOOP_INTERVAL
        end
      rescue StandardError => e
        log e
      end

      def from_remote?(ipaddr)
        Socket.ip_address_list.none? { |addr| addr.ip_address == ipaddr }
      end

      def unicast(ipaddr, msg)
        log [:message, ipaddr, msg]
        UDPSocket.open do |s|
          s.connect(ipaddr, @port)
          s.send(msg, 0)
        end
      end

      def multicast(msg)
        unicast(@multicast_addr, msg)
      end
    end
  end
end
