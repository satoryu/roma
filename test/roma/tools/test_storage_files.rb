require 'test_helper'
require 'tool_test_helper'
require 'roma/storage/hash'
require 'roma/configuration'
require 'roma/tools/storage_files'

class StorageFilesTest < Test::Unit::TestCase
  include ToolTestHelper

  def open_storage(*files, **opts)
    files.each { |f| File.write(File.join(@dir, f), '') }
    Roma::Tools::StorageFiles.open(@dir, [0], **opts)
  end

  def test_each_hash
    %w(roma2 roma1).each { |h| FileUtils.mkdir_p(File.join(@dir, h)) }
    File.write(File.join(@dir, 'file'), '')
    hashes = []
    Roma::Tools::StorageFiles.each_hash(@dir) { |hash_name, dir| hashes << [hash_name, dir] }
    assert_equal [['roma1', File.join(@dir, 'roma1')], ['roma2', File.join(@dir, 'roma2')]], hashes
  end

  def test_no_hashes
    assert_raise_message("#{@dir} has no directories of storage files.") do
      Roma::Tools::StorageFiles.each_hash(@dir) { flunk }
    end
  end

  def test_no_files
    assert_raise_message("#{@dir} has no storage files.") { open_storage }
  end

  def test_unknown_storage
    assert_raise_message("#{@dir} has files of an unknown storage: tc") { open_storage('0.tc', '1.tc') }
  end

  # The cache file is not the storage.
  def test_storage_gem_missing
    message = "The files in #{@dir} need roma-storage-dbm. Install it by gem install roma-storage-dbm."
    assert_raise_message(message) { open_storage('0.cache.dbm', '0.dbm') }
  end

  # With a storage of a test, which keeps the data on memory.
  def test_open
    storage = with_mem_storage { open_storage('0.mem', '1.mem', '0.cache.mem', '0.mem-journal') }
    assert_equal [Roma::Storage::HashStorage, 2, @dir],
                 [storage.class, storage.divnum, storage.instance_variable_get(:@storage_path)]
    assert_equal({ 0 => 0 }, storage.hdiv)
  end

  def test_open_with_division_count
    storage = with_mem_storage { open_storage('0.mem', division_count: 3) }
    assert_equal 3, storage.divnum
  end

  # New files, of the storage given.
  def test_open_new
    storage = open_storage(division_count: 4, storage_class: Roma::Storage::HashStorage)
    assert_equal [Roma::Storage::HashStorage, 4], [storage.class, storage.divnum]
  end

  def with_mem_storage
    saved = Roma::Tools::StorageFiles::STORAGES
    Roma::Tools::StorageFiles.send(:remove_const, :STORAGES)
    Roma::Tools::StorageFiles.const_set(:STORAGES,
                                        saved.merge('mem' => ['roma/storage/hash', :HashStorage, 'roma-storage']))
    yield
  ensure
    Roma::Tools::StorageFiles.send(:remove_const, :STORAGES)
    Roma::Tools::StorageFiles.const_set(:STORAGES, saved)
  end
end
