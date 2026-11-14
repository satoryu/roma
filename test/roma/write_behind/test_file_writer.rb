require 'test_helper'
require 'file_writer_tests'

class FileWriterTest < Test::Unit::TestCase
  self.test_order = :defined
  include FileWriterTests

  def teardown
    system('rm -rf wb_test')
  end
end
