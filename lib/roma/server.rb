require 'roma/romad'

module Roma
  # Runs romad, which is a daemon with -d.
  module Server
    module_function

    # +argv+ is the arguments of romad, such as ["localhost", "-p", "11211",
    # "-d"]. +program+ is the name in the usage.
    def run(argv, program: File.basename($PROGRAM_NAME))
      $roma = Roma::Romad.new(argv, program: program)
      if $roma.daemon?
        daemonize { $roma.start }
      else
        $roma.start
      end
    end

    # Runs the block in a child process of a new session, and exits. The pid
    # of the child is written to the standard error.
    def daemonize
      pid = Process.fork do
        Process.setsid
        %i(INT TERM HUP).each { |sig| Signal.trap(sig) { exit! 0 } }
        File.open(File::NULL, 'r+') do |null|
          [$stdin, $stdout, $stderr].each { |io| io.reopen(null) }
        end
        yield
      end
      $stderr.puts pid
      exit! 0
    end
  end
end
