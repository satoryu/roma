# Measures the Ruby code that a ROMA node runs for set and get, without the
# sockets and the event loop.
#
#   BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/request_path.rb [options]
#
# It makes a node in this process, as roma server does, and a connection
# that keeps its replies in a string instead of sending them. The requests
# go to the connection's receive_data, as EventMachine gives them, so the
# dispatcher, the commands and the storage run as in a node, in its Fiber.
#
# It tells the CPU time and the objects for a request. With --stackprof, it
# records the methods with StackProf, which can't tell them apart in a node:
# there the time in EventMachine's C++ code is all in
# EventMachine.run_machine, the frame that StackProf sees.
require 'optparse'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

module RequestPath
  ROMA = File.expand_path('../bin/roma', __dir__)

  # A connection without EventMachine: it keeps what it would send.
  module Offline
    attr_reader :replies

    def send_data(data)
      @replies << data
    end

    def close_connection(*)
      raise "closed: #{@replies}"
    end

    def close_connection_after_writing
      raise "closed: #{@replies}"
    end
  end

  module_function

  def parse(argv)
    options = { engine: 'hash', requests: 100_000, value_size: 100, pipeline: 1, stackprof: nil, out: '.' }
    OptionParser.new do |opts|
      opts.banner = 'Usage: BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/request_path.rb [options]'
      opts.on('-e', '--engine NAME', 'Storage engine (default: hash)') { |v| options[:engine] = v }
      opts.on('-n', '--requests NUM', Integer, 'Requests of each command (default: 100000)') do |v|
        options[:requests] = v
      end
      opts.on('-s', '--value-size BYTES', Integer, 'Size of the values (default: 100)') { |v| options[:value_size] = v }
      opts.on('--pipeline NUM', Integer, 'Requests given to receive_data at once (default: 1)') do |v|
        options[:pipeline] = v
      end
      opts.on('--stackprof MODE', %w(cpu wall object), 'Record the methods with StackProf: cpu, wall or object') do |v|
        options[:stackprof] = v
      end
      opts.on('--out DIR', 'Where --stackprof writes COMMAND.stackprof.dump and .txt (default: .)') do |v|
        options[:out] = v
      end
    end.parse!(argv)
    options
  end

  # Makes a node of +engine+ in +dir+, as roma server does, but doesn't
  # start it. Returns a connection to it.
  def connect(engine, dir)
    File.write(File.join(dir, 'config.rb'), <<~CONFIG)
      Roma.configure do |config|
        config.storage.engine = :#{engine}
        config.log.level = :warn
      end
    CONFIG
    ok = system(RbConfig.ruby, ROMA, 'route', 'create', 'localhost_11211', '--redundancy', '1',
                chdir: dir, out: File::NULL)
    raise 'roma route create failed' unless ok

    Dir.chdir(dir)
    require 'roma/server'
    # The commands find the node in $roma, as in roma server.
    server = $roma = Roma::Server.new(%w(localhost -p 11211 --config config.rb --disable-command-protection)) # rubocop:disable Style/GlobalVars
    server.storages.each_value(&:opendb)
    # The dispatcher asks how many connections there are.
    EventMachine.define_singleton_method(:connection_count) { 1 }
    conn = Roma::Command::Receiver.allocate
    conn.send(:initialize, server.storages, server.routing_table)
    conn.extend(Offline)
    conn.instance_eval do
      @replies = String.new
      @connected = true
      @fiber = Fiber.new { dispatcher }
    end
    conn
  end

  def request(command, key, value)
    command == :set ? "set #{key} 0 0 #{value.bytesize}\r\n#{value}\r\n" : "get #{key}\r\n"
  end

  def reply(command, key, value)
    command == :set ? "STORED\r\n" : "VALUE #{key} 0 #{value.bytesize}\r\n#{value}\r\nEND\r\n"
  end

  # Gives the requests of +command+ for +keys+ to +conn+, +pipeline+ at once.
  # Returns the CPU seconds and the objects allocated in receive_data.
  def measure(conn, command, keys, value, pipeline)
    batches = keys.each_slice(pipeline).map do |batch|
      [batch.map { |key| request(command, key, value) }.join, batch.map { |key| reply(command, key, value) }.join]
    end
    cpu = 0.0
    objects = 0
    batches.each do |data, expected|
      objects -= GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      conn.receive_data(data)
      cpu += Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - started
      objects += GC.stat(:total_allocated_objects)
      raise "unexpected reply: #{conn.replies[0, 200].inspect}" unless conn.replies == expected

      conn.replies.clear
    end
    [cpu, objects]
  end

  def profile(mode, path)
    return yield unless mode

    require 'stackprof'
    result = nil
    StackProf.run(mode: mode.to_sym, interval: mode == 'object' ? 1 : 100, raw: true, out: "#{path}.dump") do
      result = yield
    end
    stackprof = Gem.bin_path('stackprof', 'stackprof')
    File.write("#{path}.txt", IO.popen([stackprof, '--text', '--limit', '40', "#{path}.dump"], &:read))
    result
  end

  def main(argv)
    options = parse(argv)
    out = File.expand_path(options[:out])
    value = 'v' * options[:value_size]
    keys = Array.new(options[:requests]) { |i| "key:0:#{i}" }
    lines = ["Ruby #{RUBY_VERSION}#{' +YJIT' if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?}, " \
             "#{options[:engine]}, #{options[:requests]} requests, pipeline #{options[:pipeline]}", '',
             '| command | CPU (us/req) | objects/req |', '|---|--:|--:|']
    Dir.mktmpdir('request_path_') do |dir|
      conn = connect(options[:engine], dir)
      measure(conn, :set, keys.first(1000), value, options[:pipeline]) # Warm up.
      %i(set get).each do |command|
        path = File.join(out, "#{command}.stackprof")
        cpu, objects = profile(options[:stackprof], path) do
          measure(conn, command, keys, value, options[:pipeline])
        end
        lines << format('| %s | %.2f | %.1f |', command, cpu / keys.size * 1_000_000, objects.fdiv(keys.size))
      end
    ensure
      Dir.chdir(out)
    end
    puts lines
  end
end

RequestPath.main(ARGV) if $PROGRAM_NAME == __FILE__
