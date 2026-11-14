require 'test_helper'
require 'rbconfig'
require 'tmpdir'
require 'roma/pid_file'

class PidFileTest < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('roma_pid_file')
    @path = File.join(@dir, 'roma.pid')
    @pid_file = Roma::PidFile.new(@path)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_write_and_remove
    assert_nil @pid_file.error
    @pid_file.write
    assert_equal "#{Process.pid}\n", File.read(@path)
    @pid_file.remove
    assert_false File.exist?(@path)
  end

  # Another server has the file.
  def test_running
    File.write(@path, "#{Process.pid}\n")
    assert_equal "#{@path} has the pid #{Process.pid}, which is running.", @pid_file.error
  end

  # The process of the file is gone, and its file is overwritten.
  def test_stale
    pid = Process.spawn(RbConfig.ruby, '-e', '')
    Process.wait(pid)
    File.write(@path, "#{pid}\n")
    assert_nil @pid_file.error
    @pid_file.write
    assert_equal "#{Process.pid}\n", File.read(@path)
  end

  def test_not_writable
    pid_file = Roma::PidFile.new(File.join(@dir, 'missing', 'roma.pid'))
    assert_equal "#{pid_file.path} can't be written.", pid_file.error
  end

  # The file of another server, which overwrote it, is kept.
  def test_remove_another
    File.write(@path, "1\n")
    @pid_file.remove
    assert_equal "1\n", File.read(@path)
  end
end
