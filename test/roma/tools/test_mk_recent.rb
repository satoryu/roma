require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'mem_storage_helper'
require 'roma/storage/ruby_hash_storage'
require 'roma/tools/mk_recent'
require 'roma/configuration'

class MkRecentTest < Test::Unit::TestCase
  include ToolTestHelper
  include MemStorageHelper

  def setup
    super
    @vnodes = [0, 1 << 31]
    @recent = File.join(@dir, 'recent')
    @out = StringIO.new
  end

  def tool
    tool = Roma::Tools::MkRecent.new(out: @out)
    storages = @storages
    closed = @closed
    real = Roma::Tools::StorageFiles
    # The new files are on memory too.
    tool.define_singleton_method(:open_storage) do |dir, vnodes, divnum: nil, storage_class: nil|
      next storages.fetch(dir) { raise Roma::Tools::Error, "#{dir} has no storage files." } unless storage_class
      real.open(dir, vnodes, divnum: divnum, storage_class: storage_class).tap do |st|
        st.define_singleton_method(:closedb) { closed << dir }
        storages[dir] = st
      end
    end
    tool
  end

  def make(**opts)
    tool.make(File.join(@dir, 'a'), File.join(@dir, 'b'), @recent, hash_bits: 32, divide_bits: 1, **opts)
  end

  def get(storage, key)
    storage.get_raw2(key)&.values_at(2, 4)
  end

  # The newer data of a key, by its clock, is kept.
  def test_make
    mem_storage(File.join(@dir, 'a', 'roma'), { 'key1' => ['old', 1], 'key2' => ['a2', 5] })
    mem_storage(File.join(@dir, 'b', 'roma'), { 'key1' => ['new', 2], 'key3' => ['b3', 1] })
    make(divnum: 3)
    recent = @storages.fetch(File.join(@recent, 'roma'))
    assert_equal 3, recent.divnum
    assert_equal [[2, 'new'], [5, 'a2'], [1, 'b3']], %w(key1 key2 key3).map { |k| get(recent, k) }
    assert_equal [File.join(@dir, 'a', 'roma'), File.join(@dir, 'b', 'roma'), File.join(@recent, 'roma')].sort, @closed.sort
    assert_match(/\AOpen .*a\/roma\nOpen .*b\/roma\nOpen .*recent\/roma\nroma:0\/2\rroma:1\/2\r\n\z/, @out.string)
  end

  def test_recent_path_exists
    Dir.mkdir(@recent)
    assert_raise_message("#{@recent} exists.") { make }
  end

  def test_divide_bits_too_many
    assert_raise_message('The hash bits should be divide bits or more.') do
      tool.make('a', 'b', @recent, hash_bits: 8, divide_bits: 9)
    end
    assert_false File.exist?(@recent)
  end

  # Nothing is made then.
  def test_no_hashes
    assert_raise_message("#{File.join(@dir, 'a')} has no directories of storage files.") { make }
    assert_false File.exist?(@recent)
  end

  # The storages opened are closed.
  def test_missing_in_the_other
    mem_storage(File.join(@dir, 'a', 'roma'))
    assert_raise_message("#{File.join(@dir, 'b', 'roma')} has no storage files.") { make }
    assert_equal [File.join(@dir, 'a', 'roma')], @closed
  end

  def test_different_storages
    mem_storage(File.join(@dir, 'a', 'roma'))
    other = Class.new(Roma::Storage::RubyHashStorage)
    @storages[File.join(@dir, 'b', 'roma')] = other.new.tap do |st|
      st.divnum = 1
      st.vn_list = @vnodes
      st.opendb
      closed = @closed
      st.define_singleton_method(:closedb) { closed << :other }
    end
    assert_raise_message(/have different storages/) { make }
    assert_equal [File.join(@dir, 'a', 'roma'), :other], @closed
  end
end
