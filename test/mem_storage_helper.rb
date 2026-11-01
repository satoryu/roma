require 'roma/storage/ruby_hash_storage'
require 'roma/configuration'

# The storages are on memory, instead of the files.
module MemStorageHelper
  def setup
    super
    @storages = {}
    @closed = []
  end

  # A storage in +dir+, with +data+ as {key => [value, clock, expt]}.
  def mem_storage(dir, data = {}, divnum: 2, vnodes: [0, 1 << 31])
    FileUtils.mkdir_p(dir)
    storage = Roma::Storage::RubyHashStorage.new
    storage.divnum = divnum
    storage.vn_list = vnodes
    storage.each_vn_dump_sleep = 0
    storage.opendb
    data.each do |key, (value, clk, expt)|
      vn = vnodes[key.sum % vnodes.size]
      storage.set(vn, key, 0, expt || 0x7fffffff, value)
      storage.instance_variable_get(:@hdb)[storage.hdiv[vn]].tap do |hdb|
        vn_, last, _clk, ex, val = hdb[key].unpack('NNNNa*')
        hdb[key] = [vn_, last, clk || 0, ex, val].pack('NNNNa*')
      end
    end
    closed = @closed
    storage.define_singleton_method(:closedb) { closed << dir }
    @storages[dir] = storage
  end

  # Makes +tool+ open the storages of mem_storage.
  def use_mem_storages(tool)
    storages = @storages
    tool.define_singleton_method(:open_storage) { |dir, *| storages.fetch(dir) { raise Roma::Tools::Error, "#{dir} has no storage files." } }
    tool
  end
end
