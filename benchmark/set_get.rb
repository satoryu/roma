# Measures set and get on a ROMA node with each storage engine, and on Redis.
#
#   BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb [options]
#
# For each target it starts a server in a temporary directory, sets keys from
# client processes, gets the same keys, stops the server and writes the
# results as a Markdown table. A ROMA node runs alone with redundancy 1, so it
# does no replication, and Redis keeps nothing on disk.
#
# The clients talk to ROMA (the memcached text protocol) and to Redis (RESP)
# with the same small socket code, so only the servers differ. Each client is
# a process with its own connection, and sends a request after the reply of
# the last one.
require 'optparse'
require 'rbconfig'
require 'socket'
require 'tmpdir'
require 'fileutils'
require 'json'

module SetGetBenchmark
  ROMA = File.expand_path('../bin/roma', __dir__)
  ENGINES = %w(hash groonga sqlite3 dbm).freeze
  TARGETS = [*ENGINES, 'redis'].freeze

  # A reply that isn't the one expected.
  class Failed < StandardError; end

  # Sends requests in the memcached text protocol, which ROMA speaks.
  class TextClient
    def initialize(port)
      @sock = TCPSocket.new('127.0.0.1', port)
      @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    end

    def set(key, value)
      @sock.write("set #{key} 0 0 #{value.bytesize}\r\n#{value}\r\n")
      expect("STORED\r\n")
    end

    # Returns nil when the key is missing.
    def get(key)
      @sock.write("get #{key}\r\n")
      line = @sock.gets
      return nil unless line.start_with?('VALUE')

      value = @sock.read(line.split[3].to_i + 2).chomp("\r\n")
      @sock.gets # END
      value
    end

    def close
      @sock.close
    end

    private

    def expect(reply)
      line = @sock.gets
      raise Failed, line.inspect unless line == reply
    end
  end

  # Sends requests in RESP, which Redis speaks.
  class RespClient < TextClient
    def set(key, value)
      @sock.write(command('SET', key, value))
      expect("+OK\r\n")
    end

    def get(key)
      @sock.write(command('GET', key))
      size = @sock.gets[1..].to_i
      return nil if size.negative?

      @sock.read(size + 2).chomp("\r\n")
    end

    private

    def command(*args)
      "*#{args.size}\r\n" + args.map { |a| "$#{a.bytesize}\r\n#{a}\r\n" }.join
    end
  end

  # A server that runs while the block of run does.
  class Server
    attr_reader :name, :port

    def initialize(name, port)
      @name = name
      @port = port
    end

    def run(keep: false)
      dir = Dir.mktmpdir("set_get_#{name}_")
      @pid = Process.spawn(*command(dir), chdir: dir, out: File.join(dir, 'server.out'), err: %i(child out))
      wait_until_ready
      yield
    ensure
      stop
      keep ? warn("#{name}: kept #{dir}") : FileUtils.rm_rf(dir)
    end

    private

    # Retries a set until it is stored. A ROMA node takes only its system
    # commands until it has checked the other nodes, about 10 seconds after
    # it starts.
    def wait_until_ready(timeout = 60)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until ready?
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "#{name} didn't start. See server.out (--keep keeps it)."
        end

        sleep 0.5
      end
    end

    def ready?
      client = client_class.new(port)
      client.set('set_get_ready', '1')
      true
    rescue SystemCallError, IOError, Failed
      false
    ensure
      client&.close
    end

    def stop
      return unless @pid

      Process.kill(:TERM, @pid)
      return if exited_within?(10)

      Process.kill(:KILL, @pid)
      Process.wait(@pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @pid = nil
    end

    def exited_within?(seconds)
      (seconds * 10).times do
        return true if Process.wait(@pid, Process::WNOHANG)

        sleep 0.1
      end
      false
    end
  end

  # A ROMA node with a storage engine.
  class RomaServer < Server
    def initialize(engine, port)
      super
      @engine = engine
    end

    def client_class
      TextClient
    end

    def version
      require 'roma/version'
      "ROMA #{Roma::VERSION}"
    end

    private

    def command(dir)
      File.write(File.join(dir, 'config.rb'), <<~CONFIG)
        Roma.configure do |config|
          config.storage.engine = :#{@engine}
          config.log.level = :warn
        end
      CONFIG
      node_id = "localhost_#{port}"
      ok = system(RbConfig.ruby, ROMA, 'route', 'create', node_id, '--redundancy', '1',
                  chdir: dir, out: File::NULL)
      raise "roma route create #{node_id} failed" unless ok

      [RbConfig.ruby, ROMA, 'server', 'localhost', '-p', port.to_s, '--config', 'config.rb']
    end
  end

  # A Redis server that keeps nothing on disk.
  class RedisServer < Server
    def initialize(port, redis_server)
      super('redis', port)
      @redis_server = redis_server
    end

    def client_class
      RespClient
    end

    def version
      IO.popen([@redis_server, '--version'], &:read)[/v=(\S+)/, 1].then { |v| "Redis #{v}" }
    end

    private

    def command(_dir)
      [@redis_server, '--port', port.to_s, '--bind', '127.0.0.1', '--save', '', '--appendonly', 'no']
    end
  end

  # The results of a command on a target.
  Result = Struct.new(:target, :command, :requests, :seconds, :latencies, :errors) do
    def ops_per_second
      requests / seconds
    end

    # The latency at +percent+ in milliseconds.
    def percentile(percent)
      latencies[((latencies.size - 1) * percent / 100.0).round] * 1000
    end
  end

  # Sends +requests+ set or get requests from each of +clients+ processes,
  # and measures how fast.
  class Runner
    def initialize(clients:, requests:, value_size:, warmup:)
      @clients = clients
      @requests = requests
      @value = 'v' * value_size
      @warmup = warmup
    end

    def run(server)
      warm_up(server)
      %i(set get).map { |command| measure(server, command) }
    end

    private

    def warm_up(server)
      client = server.client_class.new(server.port)
      @warmup.times { |i| client.set("warmup:#{i}", @value) }
      client.close
    end

    # The clients start together after they connect. The time is from the
    # start until the last client finishes.
    def measure(server, command)
      start_r, start_w = IO.pipe
      workers = Array.new(@clients) do |n|
        r, w = IO.pipe
        pid = fork do
          r.close
          start_w.close
          client = server.client_class.new(server.port)
          start_r.read(1)
          w.write(JSON.generate(send_requests(client, command, n)))
          w.close
          exit!(0)
        end
        w.close
        [pid, r]
      end
      start_r.close
      sleep 0.5 # Let the clients connect.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      start_w.write('x' * @clients)
      start_w.close
      reports = workers.map do |pid, r|
        report = JSON.parse(r.read, symbolize_names: true)
        r.close
        Process.wait(pid)
        report
      end
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      latencies = reports.flat_map { |report| report[:latencies] }.sort
      Result.new(server.name, command, latencies.size, seconds, latencies, reports.sum { |report| report[:errors] })
    end

    # Client +n+ uses its own keys. A get fails if the value isn't the one set.
    def send_requests(client, command, n)
      latencies = Array.new(@requests)
      errors = 0
      @requests.times do |i|
        key = "key:#{n}:#{i}"
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ok = succeeded?(client, command, key)
        latencies[i] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
        errors += 1 unless ok
      end
      { latencies: latencies, errors: errors }
    end

    def succeeded?(client, command, key)
      return client.get(key) == @value if command == :get

      client.set(key, @value)
      true
    rescue Failed
      false
    end
  end

  module_function

  def parse(argv)
    options = { targets: TARGETS, clients: 4, requests: 10_000, value_size: 100, warmup: 1000,
                port: 21_300, redis_server: 'redis-server', keep: false }
    OptionParser.new do |opts|
      opts.banner = 'Usage: BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb [options]'
      opts.on('-t', '--targets LIST', Array, "Targets to measure (default: #{TARGETS.join(',')})") do |v|
        unknown = v - TARGETS
        raise OptionParser::InvalidArgument, unknown.join(',') unless unknown.empty?

        options[:targets] = v
      end
      opts.on('-c', '--clients NUM', Integer, 'Client processes (default: 4)') { |v| options[:clients] = v }
      opts.on('-n', '--requests NUM', Integer, 'Requests of each command from each client (default: 10000)') do |v|
        options[:requests] = v
      end
      opts.on('-s', '--value-size BYTES', Integer, 'Size of the values (default: 100)') { |v| options[:value_size] = v }
      opts.on('-w', '--warmup NUM', Integer, 'Sets before measuring (default: 1000)') { |v| options[:warmup] = v }
      opts.on('-p', '--port PORT', Integer, 'Port of the servers (default: 21300)') { |v| options[:port] = v }
      opts.on('--redis-server PATH', 'redis-server to run (default: redis-server)') { |v| options[:redis_server] = v }
      opts.on('--keep', 'Keep the directories of the servers, with their output') { options[:keep] = true }
    end.parse!(argv)
    options
  end

  def server(target, options)
    if target == 'redis'
      RedisServer.new(options[:port], options[:redis_server])
    else
      RomaServer.new(target, options[:port])
    end
  end

  def main(argv)
    options = parse(argv)
    runner = Runner.new(**options.slice(:clients, :requests, :value_size, :warmup))
    results = []
    versions = []
    options[:targets].each do |target|
      server = server(target, options)
      warn "Measuring #{target} ..."
      server.run(keep: options[:keep]) { results.concat(runner.run(server)) }
      versions << server.version
    end
    puts report(results, options, versions.uniq)
  end

  def report(results, options, versions)
    lines = []
    lines << "Ruby #{RUBY_VERSION}, #{versions.join(', ')}, #{RbConfig::CONFIG['host_os']}"
    lines << "#{options[:clients]} clients x #{options[:requests]} requests, values of #{options[:value_size]} bytes"
    lines << ''
    lines << '| target | command | ops/s | p50 (ms) | p99 (ms) | max (ms) | errors |'
    lines << '|---|---|--:|--:|--:|--:|--:|'
    results.each do |r|
      lines << format('| %s | %s | %.0f | %.3f | %.3f | %.3f | %d |', r.target, r.command, r.ops_per_second,
                      r.percentile(50), r.percentile(99), r.percentile(100), r.errors)
    end
    lines.join("\n")
  end
end

SetGetBenchmark.main(ARGV) if $PROGRAM_NAME == __FILE__
