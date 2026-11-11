require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/tools/directory_creator'

class DirectoryCreatorTest < Test::Unit::TestCase
  include ToolTestHelper

  def setup
    super
    @path = File.join(@dir, 'myroma')
  end

  def teardown
    Roma.reset_config
    super
  end

  def create(dir = @path, **)
    out = StringIO.new
    Roma::Tools::DirectoryCreator.new(out: out).create(dir, **)
    out.string
  end

  def read(name)
    File.read(File.join(@path, name))
  end

  def files
    Dir.glob('**/*', File::FNM_DOTMATCH, base: @path).reject { |f| File.basename(f) == '.' }.sort
  end

  def test_create
    out = create
    assert_equal %w(.gitignore Gemfile command_plugins command_plugins/.keep config.rb log log/.keep routing
                    routing/localhost_12000.route.yml), files
    assert_match(/^  create  config.rb$/, out)
    assert_match(%r{^  create  routing/localhost_12000.route.yml$}, out)
    assert_match(/^  bundle exec roma server localhost --config config.rb$/, out)

    Roma.load_config(File.join(@path, 'config.rb'))
    config = Roma.config
    assert_equal 12_000, config.port
    assert_equal :hash, config.storage.engine
    assert_equal %w(data routing log wb command_plugins),
                 [config.storage.path, config.routing.path, config.log.path, config.write_behind.path,
                  config.command_plugin_path]
    assert_nil config.pid_file

    assert_equal "source 'https://rubygems.org'\n\ngem 'roma', '~> #{Roma::VERSION}'\n", read('Gemfile')

    routing_data = Roma::Routing::RoutingData.load_snapshot(File.join(@path, 'routing/localhost_12000.route.yml'))
    assert_equal %w(localhost_12000), routing_data.nodes
    assert_equal 1, routing_data.redundancy
  end

  def test_options
    create(address: 'roma1', port: 11_211, storage: 'dbm')
    assert_true File.exist?(File.join(@path, 'routing/roma1_11211.route.yml'))
    Roma.load_config(File.join(@path, 'config.rb'))
    assert_equal [11_211, :dbm], [Roma.config.port, Roma.config.storage.engine]
    assert_equal "source 'https://rubygems.org'\n\ngem 'roma', '~> #{Roma::VERSION}'\ngem 'roma-storage-dbm'\n",
                 read('Gemfile')
  end

  def test_dev
    create(dev: true)
    assert_match(/^gem 'roma', path: '#{Regexp.escape(File.expand_path('../../..', __dir__))}'$/, read('Gemfile'))
  end

  # An empty directory is taken.
  def test_empty_directory
    Dir.mkdir(@path)
    create
    assert_true File.exist?(File.join(@path, 'config.rb'))
  end

  def test_not_empty
    Dir.mkdir(@path)
    File.write(File.join(@path, 'config.rb'), 'mine')
    error = assert_raise(Roma::Tools::Error) { create }
    assert_equal "#{@path} is not empty.", error.message
    assert_equal 'mine', read('config.rb')
    assert_equal %w(config.rb), files
  end

  def test_file
    File.write(@path, 'mine')
    error = assert_raise(Roma::Tools::Error) { create }
    assert_equal "#{@path} is not empty.", error.message
  end

  # Wrong settings make nothing.
  data('port' => [{ port: 0 }, 'port should be a valid Integer: 0'],
       'storage' => [{ storage: 'Dbm' }, 'storage.engine should be a valid Symbol or Class: :Dbm'])
  def test_invalid_settings(data)
    options, message = data
    error = assert_raise(Roma::Tools::Error) { create(**options) }
    assert_equal message, error.message
    assert_false File.exist?(@path)
  end
end
