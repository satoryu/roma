require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'stringio'
require 'fake_node'

module ToolTestHelper
  BIN_DIR = File.expand_path('../bin', __dir__)

  def setup
    @dir = Dir.mktmpdir('roma_tools')
    @nodes = []
  end

  def teardown
    @nodes.each(&:close)
    Roma::Messaging::ConPool.instance.close_all
    FileUtils.rm_rf(@dir)
  end

  def fake_node
    FakeNode.new.tap { |node| @nodes << node }
  end

  # Runs a command in bin/ in another process, since the tools run when they
  # are loaded and some exit. With COVERAGE, it is measured too.
  def run_tool(name, *, stdin: '')
    cmd = [RbConfig.ruby]
    cmd.push('-r', File.expand_path('start_coverage', __dir__)) if ENV['COVERAGE']
    cmd.push(File.join(BIN_DIR, name), *)
    Open3.capture3(*cmd, stdin_data: stdin, chdir: @dir)
  end

  # Makes +node+ answer routingdump with +routing_data+.
  def serve_routing(node, routing_data)
    dump = Marshal.dump(routing_data)
    node.replies['routingdump'] = "#{dump.bytesize}\r\n#{dump}\r\nEND\r\n"
  end

  # A node id that nothing listens on.
  def down_node
    server = TCPServer.new(0)
    "localhost_#{server.addr[1]}"
  ensure
    server.close
  end

  def capture_stdout
    saved = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = saved
  end
end
