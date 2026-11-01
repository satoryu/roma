require 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
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
    assert_equal :ruby_hash, @config.storage.engine
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
       'unknown engine' => [->(c) { c.storage.engine = :tc }, /\Astorage.engine should be a valid Symbol or Class: :tc\z/],
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
    require 'roma/storage/ruby_hash_storage'
    assert_same Roma::Storage::RubyHashStorage, @config.storage.engine_class
    klass = Class.new
    @config.storage.engine = klass
    assert_same klass, @config.storage.engine_class
  end

  def test_engine_class_missing_gem
    saved = Roma::Configuration::STORAGE_ENGINES
    Roma::Configuration.send(:remove_const, :STORAGE_ENGINES)
    Roma::Configuration.const_set(:STORAGE_ENGINES, { missing: ['roma/storage/missing', :Missing, 'roma-storage-missing'] })
    @config.storage.engine = :missing
    error = assert_raise(Roma::Configuration::Error) { @config.storage.engine_class }
    assert_equal 'storage.engine :missing needs roma-storage-missing. Install it by gem install roma-storage-missing.',
                 error.message
  ensure
    Roma::Configuration.send(:remove_const, :STORAGE_ENGINES)
    Roma::Configuration.const_set(:STORAGE_ENGINES, saved)
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
