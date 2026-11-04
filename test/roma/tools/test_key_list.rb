require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'mem_storage_helper'
require 'roma/tools/key_list'

class KeyListTest < Test::Unit::TestCase
  include ToolTestHelper
  include MemStorageHelper

  def test_list
    mem_storage(File.join(@dir, 'roma'), { 'key1' => ['v1'], 'key2' => ['v2'], 'expired' => ['v3', 0, 1] })
    mem_storage(File.join(@dir, 'roma2'), { 'key3' => ['v4'] })
    out = StringIO.new
    err = StringIO.new
    use_mem_storages(Roma::Tools::KeyList.new(out: out, err: err, wait: 0)).list(@dir)
    assert_equal %w(key1 key2 key3), out.string.lines.map(&:chomp).sort
    assert_match(%r{\A### roma #{@dir}/roma\n.*done\n### roma2 #{@dir}/roma2\n.*done\n\z}m, err.string)
    assert_match(%r{1/3\r2/3\r}, err.string)
    assert_equal [File.join(@dir, 'roma'), File.join(@dir, 'roma2')], @closed
  end

  # The storage is closed even then.
  def test_error
    storage = mem_storage(File.join(@dir, 'roma'), { 'key1' => ['v1'] })
    def storage.true_length
      raise Roma::Tools::Error, 'broken'
    end
    tool = use_mem_storages(Roma::Tools::KeyList.new(out: StringIO.new, err: StringIO.new))
    assert_raise_message('broken') { tool.list(@dir) }
    assert_equal [File.join(@dir, 'roma')], @closed
  end
end
