require 'roma/storage/hash'
require 'roma/configuration'

# The storages are on memory, instead of the files.
module MemStorageHelper
  def setup
    super
    @storages = {}
    @closed = []
  end

  # A storage in +dir+, with +data+ as {key => [value, clock, expire_time]}.
  def mem_storage(dir, data = {}, division_count: 2, vnodes: [0, 1 << 31])
    FileUtils.mkdir_p(dir)
    storage = Roma::Storage::HashStorage.new
    storage.divnum = division_count
    storage.vn_list = vnodes
    storage.each_vn_dump_sleep = 0
    storage.opendb
    data.each do |key, (value, clock, expire_time)|
      vnode = vnodes[key.sum % vnodes.size]
      storage.set(vnode, key, 0, expire_time || 0x7fffffff, value)
      storage.instance_variable_get(:@hdb)[storage.hdiv[vnode]].tap do |hdb|
        vn_, last, _clk, ex, val = hdb[key].unpack('NNNNa*')
        hdb[key] = [vn_, last, clock || 0, ex, val].pack('NNNNa*')
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
