require 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require 'roma/configuration'

class ConfigurationTest < Test::Unit::TestCase
  def setup
    @config = Roma::Configuration::Settings.new
  end

  def test_defaults
    assert_equal 'ROMA', @config.name
    assert_equal 12000, @config.port
    assert_equal ['plugin_storage.rb'], @config.plugins
    assert_equal :auto_assign, @config.routing.lost_action
    assert_equal :debug, @config.log.level
    assert_equal 5, @config.connection.pool.max
    assert_equal 15, @config.connection.em_pool.max
    assert_equal 30, @config.connection.em_pool.expire_time
    assert_equal :hash, @config.storage.engine
    assert_equal({}, @config.write_behind.command_map)
  end

  # A mutable default is not shared with another config.
  def test_defaults_are_copied
    @config.plugins << 'plugin_alist.rb'
    @config.routing.sub_nid['10.0.0.0/8'] = {}
    other = Roma::Configuration::Settings.new
    assert_equal ['plugin_storage.rb'], other.plugins
    assert_equal({}, other.routing.sub_nid)
  end

  def test_set
    @config.port = 11211
    @config.log.level = :info
    @config.connection.pool.max = 10
    @config.storage.engine = Class.new
    @config.storage.option = nil
    assert_equal 11211, @config.port
    assert_equal :info, @config.log.level
    assert_equal 10, @config.connection.pool.max
    assert_nil @config.storage.option
  end

  data('type' => [->(c) { c.port = '11211' }, /\Aport should be a valid Integer: "11211"\z/],
       'check' => [->(c) { c.port = 0 }, /\Aport should be a valid Integer: 0\z/],
       'one of' => [->(c) { c.routing.lost_action = :foo },
                    /\Arouting.lost_action should be one of :no_action, :auto_assign, :shutdown: :foo\z/],
       'boolean' => [->(c) { c.connection.use_epoll = 'yes' }, /\Aconnection.use_epoll should be one of true, false/],
       'nested' => [->(c) { c.connection.pool.max = 1.5 }, /\Aconnection.pool.max should be a valid Integer: 1.5\z/],
       'continuous limit' => [->(c) { c.connection.continuous_limit = '1:2' }, /continuous_limit should be/],
       'engine' => [->(c) { c.storage.engine = :'my-kvs' }, /\Astorage.engine should be a valid Symbol or Class: :"my-kvs"\z/],
       'plugins' => [->(c) { c.plugins = [1] }, /\Aplugins should be/])
  def test_wrong_value(data)
    set, message = data
    error = assert_raise(Roma::Configuration::Error) { set.call(@config) }
    assert_match message, error.message
  end

  def test_unknown_setting
    assert_raise(NoMethodError) { @config.log.size = 1 }
  end

  def test_engine_class
    require 'roma/storage/hash'
    assert_same Roma::Storage::HashStorage, @config.storage.engine_class
    klass = Class.new
    @config.storage.engine = klass
    assert_same klass, @config.storage.engine_class
  end

  # A storage of another gem, which has roma/storage/<name>.rb.
  def test_engine_class_by_name
    with_storage_file('my_kvs', "module Roma\n  module Storage\n    class MyKVSStorage; end\n  end\nend\n") do
      @config.storage.engine = :my_kvs
      assert_equal 'Roma::Storage::MyKVSStorage', @config.storage.engine_class.name
    end
  end

  def test_engine_class_missing_gem
    @config.storage.engine = :missing
    error = assert_raise(Roma::Configuration::Error) { @config.storage.engine_class }
    assert_equal 'storage.engine :missing needs roma-storage-missing. Install it by gem install roma-storage-missing.',
                 error.message
  end

  def test_engine_class_missing_class
    with_storage_file('no_class', "# no storage class\n") do
      @config.storage.engine = :no_class
      error = assert_raise(Roma::Configuration::Error) { @config.storage.engine_class }
      assert_equal 'roma/storage/no_class has no storage class such as Roma::Storage::NoClassStorage.', error.message
    end
  end

  # A LoadError in the storage file is not taken as a missing gem.
  def test_engine_class_load_error_in_file
    with_storage_file('broken', "require 'roma/storage/missing_dependency'\n") do
      @config.storage.engine = :broken
      error = assert_raise(LoadError) { @config.storage.engine_class }
      assert_equal 'roma/storage/missing_dependency', error.path
    end
  end

  # Makes roma/storage/<name>.rb with +body+ in a load path while the block runs.
  def with_storage_file(name, body)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'roma/storage'))
      File.write(File.join(dir, "roma/storage/#{name}.rb"), body)
      $LOAD_PATH.unshift(dir)
      yield
    ensure
      $LOAD_PATH.delete(dir)
    end
  end

  def test_to_h
    h = @config.to_h
    assert_equal 12000, h['port']
    assert_equal :debug, h['log.level']
    assert_equal 5, h['connection.pool.max']
    assert_equal 15, h['connection.em_pool.max']
  end

  # Roma.configure, Roma.load_config and Roma.reset_config change the
  # settings of the process, so they run in another one.
  def run_ruby(code)
    Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e',
                   "require 'roma/configuration'\n#{code}")
  end

  def test_configure_and_reset
    out, err, status = run_ruby(<<~RUBY)
      Roma.configure { |config| config.port = 11211; config.log.level = :warn }
      p [Roma.config.port, Roma.config.log.level]
      Roma.reset_config
      p Roma.config.port
    RUBY
    assert_true status.success?, err
    assert_equal "[11211, :warn]\n12000\n", out
  end

  def test_load_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.rb')
      File.write(path, "Roma.configure { |config| config.storage.path = '/data' }\n")
      out, err, status = run_ruby(<<~RUBY)
        Roma.configure { |config| config.port = 11211 }
        Roma.load_config(#{path.dump})
        p [Roma.config.port, Roma.config.storage.path]
      RUBY
      assert_true status.success?, err
      assert_equal "[12000, \"/data\"]\n", out
    end
  end

  def test_load_config_of_old_format
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.rb')
      File.write(path, "module Roma\n  module Config\n    DEFAULT_PORT = 11211\n  end\nend\n")
      _out, err, status = run_ruby("Roma.load_config(#{path.dump})")
      assert_false status.success?
      assert_match(/#{Regexp.escape(path)} defines Roma::Config, which ROMA 2.0 doesn't read\./, err)
    end
  end
end
