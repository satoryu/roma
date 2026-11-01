require 'test_helper'
require 'file_writer_tests'

class FileWriterTest < Test::Unit::TestCase
  self.test_order = :defined
  include FileWriterTests

  def setup
    @stats = Roma::Stats.instance
    @stats.address = 'roma0'
    @stats.port = 11_211
  end

  def teardown
    system('rm -rf wb_test')
  end
end
