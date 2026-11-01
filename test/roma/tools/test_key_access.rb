require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'mem_storage_helper'
require 'roma/tools/key_access'

class KeyAccessTest < Test::Unit::TestCase
  include ToolTestHelper
  include MemStorageHelper

  def setup
    super
    mem_storage(File.join(@dir, 'roma'), { 'key1' => ['v1', 3], 'expired' => ['v2', 0, 1] })
    mem_storage(File.join(@dir, 'roma2'), { 'key2' => ['v3'] })
    @out = StringIO.new
  end

  def access(key, **opts)
    use_mem_storages(Roma::Tools::KeyAccess.new(out: @out)).access(@dir, key, **opts)
  end

  def test_exist
    assert_true access('key1')
    assert_equal "hash : roma\nexist\n", @out.string
    assert_equal [File.join(@dir, 'roma')], @closed
  end

  def test_in_another_hash
    assert_true access('key2')
    assert_equal "hash : roma\nhash : roma2\nexist\n", @out.string
  end

  def test_value
    access('key1', value: true)
    assert_match(/\Ahash : roma\nvnode: \d+\nlast : .+\nclock: 3\nexpt : .+\nvalue: v1\n\z/, @out.string)
  end

  data('missing' => 'key3', 'expired' => 'expired')
  def test_not_exist(key)
    assert_false access(key)
    assert_equal "hash : roma\nhash : roma2\nnot exist\n", @out.string
  end

  # A deleted key leaves a mark, whose expt is 0.
  def test_deleted
    storage = @storages[File.join(@dir, 'roma')]
    vn = [0, 1 << 31]['key1'.sum % 2]
    storage.delete(vn, 'key1', 0)
    assert_false access('key1')
  end
end
