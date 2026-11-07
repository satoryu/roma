# Measures set and get on a ROMA node with each storage engine, and on Redis.
#
#   BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb [options]
#
# For each target it starts a server in a temporary directory, sets keys from
# client processes, gets the same keys, stops the server and writes the
# results as Markdown tables: how fast, and how much memory and disk the
# server uses for the keys. A ROMA node runs alone with redundancy 1, so it
# does no replication, and Redis keeps nothing on disk.
#
# The clients talk to ROMA (the memcached text protocol) and to Redis (RESP)
# with the same small socket code, so only the servers differ. Each client is
# a process with its own connection, and sends a request after the reply of
# the last one.
#
# --yjit runs the ROMA nodes with YJIT, or both without and with it; the
# clients are the same either way.
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
      @dir = Dir.mktmpdir("set_get_#{name}_")
      @pid = Process.spawn(*command(@dir), chdir: @dir, out: File.join(@dir, 'server.out'), err: %i(child out))
      wait_until_ready
      yield
    ensure
      stop
      keep ? warn("#{name}: kept #{@dir}") : FileUtils.rm_rf(@dir)
    end

    # The resident memory of the server. It includes the pages of the files
    # that the server maps and has touched.
    def rss_bytes
      Integer(IO.popen(['ps', '-o', 'rss=', '-p', @pid.to_s], &:read).strip) * 1024
    end

    # The CPU time that the server has used, from ps: [[H:]M]M:SS[.ss].
    def cpu_seconds
      IO.popen(['ps', '-o', 'time=', '-p', @pid.to_s], &:read).strip.split(':').map(&:to_f)
        .inject { |sum, part| (sum * 60) + part }
    end

    # The disk space of the data, or nil if the server keeps none.
    def disk_bytes
      dir = data_dir
      return nil unless dir

      Dir.glob('**/*', base: dir).sum do |f|
        stat = File.stat(File.join(dir, f))
        stat.file? ? stat.blocks * 512 : 0
      end
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

  # A ROMA node with a storage engine, run with YJIT if +yjit+.
  class RomaServer < Server
    def initialize(engine, port, yjit: false)
      super(yjit ? "#{engine}+yjit" : engine, port)
      @engine = engine
      @yjit = yjit
    end

    def client_class
      TextClient
    end

    def version
      require 'roma/version'
      "ROMA #{Roma::VERSION}"
    end

    private

    # The storage files are in NODE_ID/HASH_NAME under storage.path. The
    # hash storage has none.
    def data_dir
      File.join(@dir, "localhost_#{port}") unless @engine == 'hash'
    end

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

      [RbConfig.ruby, *('--yjit' if @yjit), ROMA, 'server', 'localhost', '-p', port.to_s, '--config', 'config.rb']
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

    def data_dir
      nil
    end

    def command(_dir)
      [@redis_server, '--port', port.to_s, '--bind', '127.0.0.1', '--save', '', '--appendonly', 'no']
    end
  end

  # The results of a command on a target.
  Result = Struct.new(:target, :command, :requests, :seconds, :latencies, :errors, :cpu_seconds) do
    def ops_per_second
      requests / seconds
    end

    # The CPU time of the server for a request, in microseconds. Unlike
    # ops/s, it doesn't depend on whether the clients keep the server busy.
    def cpu_per_request
      cpu_seconds / requests * 1_000_000
    end

    # The latency at +percent+ in milliseconds.
    def percentile(percent)
      latencies[((latencies.size - 1) * percent / 100.0).round] * 1000
    end
  end

  # How much memory and disk a target used for +keys+ keys.
  Usage = Struct.new(:target, :keys, :rss_before, :rss_after, :disk) do
    def rss_per_key
      (rss_after - rss_before).fdiv(keys)
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

    # Returns the Results of set and get, and the Usage after the set.
    def run(server)
      warm_up(server)
      rss_before = server.rss_bytes
      set = measure(server, :set)
      usage = Usage.new(server.name, @clients * @requests, rss_before, server.rss_bytes, server.disk_bytes)
      [[set, measure(server, :get)], usage]
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
      cpu = server.cpu_seconds
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
      cpu = server.cpu_seconds - cpu
      latencies = reports.flat_map { |report| report[:latencies] }.sort
      errors = reports.sum { |report| report[:errors] }
      Result.new(server.name, command, latencies.size, seconds, latencies, errors, cpu)
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
                port: 21_300, redis_server: 'redis-server', keep: false, yjit: 'off' }
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
      opts.on('--yjit MODE', %w(off on both), 'Run the ROMA nodes with YJIT: off, on or both (default: off)') do |v|
        abort 'This Ruby has no YJIT.' unless defined?(RubyVM::YJIT)

        options[:yjit] = v
      end
      opts.on('--keep', 'Keep the directories of the servers, with their output') { options[:keep] = true }
    end.parse!(argv)
    options
  end

  # The servers to measure, in order. Redis runs once whatever --yjit is.
  def servers(options)
    yjits = { 'off' => [false], 'on' => [true], 'both' => [false, true] }.fetch(options[:yjit])
    options[:targets].flat_map do |target|
      if target == 'redis'
        [RedisServer.new(options[:port], options[:redis_server])]
      else
        yjits.map { |yjit| RomaServer.new(target, options[:port], yjit: yjit) }
      end
    end
  end

  def main(argv)
    options = parse(argv)
    runner = Runner.new(**options.slice(:clients, :requests, :value_size, :warmup))
    results = []
    usages = []
    versions = []
    servers(options).each do |server|
      warn "Measuring #{server.name} ..."
      server.run(keep: options[:keep]) do
        target_results, usage = runner.run(server)
        results.concat(target_results)
        usages << usage
      end
      versions << server.version
    end
    puts report(results, usages, options, versions.uniq)
  end

  MB = 1024.0 * 1024

  def report(results, usages, options, versions)
    lines = []
    lines << "Ruby #{RUBY_VERSION}, #{versions.join(', ')}, #{RbConfig::CONFIG['host_os']}"
    lines << "#{options[:clients]} clients x #{options[:requests]} requests, values of #{options[:value_size]} bytes"
    lines << ''
    lines << '| target | command | ops/s | p50 (ms) | p99 (ms) | max (ms) | server CPU (us/req) | errors |'
    lines << '|---|---|--:|--:|--:|--:|--:|--:|'
    results.each do |r|
      lines << format('| %s | %s | %.0f | %.3f | %.3f | %.3f | %.1f | %d |', r.target, r.command, r.ops_per_second,
                      r.percentile(50), r.percentile(99), r.percentile(100), r.cpu_per_request, r.errors)
    end
    lines << ''
    lines << '| target | keys | RSS before set (MB) | RSS after set (MB) | RSS per key (bytes) | disk (MB) |'
    lines << '|---|--:|--:|--:|--:|--:|'
    usages.each do |u|
      disk = u.disk ? format('%.1f', u.disk / MB) : '-'
      lines << format('| %s | %d | %.1f | %.1f | %.0f | %s |', u.target, u.keys, u.rss_before / MB,
                      u.rss_after / MB, u.rss_per_key, disk)
    end
    lines.join("\n")
  end
end

SetGetBenchmark.main(ARGV) if $PROGRAM_NAME == __FILE__
