require 'fileutils'
require 'stringio'
require 'roma/version'
require 'roma/configuration'
require 'roma/routing/routing_data'
require 'roma/tools/error'
require 'roma/tools/route_creator'

module Roma
  module Tools
    # Makes a directory to run roma server in, as roma new does: config.rb,
    # Gemfile, the routing table of a node, and the directories for the
    # command plugins and the logs.
    class DirectoryCreator
      # Where this ROMA is, for the Gemfile of dev.
      ROMA_ROOT = File.expand_path('../../..', __dir__)

      # The files that the nodes make.
      GITIGNORE = <<~GITIGNORE.freeze
        /data/
        /log/*.log*
        /routing/*.route.[0-9]*
        /wb/
        *.pid
      GITIGNORE

      # +out+ is where messages go.
      def initialize(out: $stdout)
        @out = out
      end

      # Makes +dir+ for a node of +address+ and +port+, with the storage
      # engine +storage+. With +dev+, the Gemfile takes ROMA from this
      # directory, instead of the released gem. Raises Error if +dir+ has
      # files, or the settings are wrong.
      def create(dir, address: 'localhost', port: 12_000, storage: 'hash', dev: false)
        raise Error, "#{dir} is not empty." if File.exist?(dir) && !(File.directory?(dir) && Dir.empty?(dir))

        settings = Roma::Configuration::Settings.new
        settings.port = port
        settings.storage.engine = storage.to_sym
        node_id = "#{address}_#{port}"

        %w(command_plugins log routing).each { |name| FileUtils.mkdir_p(File.join(dir, name)) }
        write(dir, 'config.rb', config_body(settings))
        write(dir, 'Gemfile', gemfile_body(settings.storage.engine, dev))
        write(dir, '.gitignore', GITIGNORE)
        write(dir, 'command_plugins/.keep', '')
        write(dir, 'log/.keep', '')
        RouteCreator.new(out: StringIO.new, dir: File.join(dir, 'routing')).create([node_id], redundancy: 1)
        @out.puts "  create  routing/#{Roma::Routing::RoutingData.file_name(node_id)}"

        @out.puts <<~NEXT

          #{dir} has been made. Run the node in it by
            cd #{dir}
            bundle install
            bundle exec roma server #{address} --config config.rb
        NEXT
      rescue Roma::Configuration::Error => e
        raise Error, e.message
      end

      private

      def write(dir, name, body)
        File.write(File.join(dir, name), body)
        @out.puts "  create  #{name}"
      end

      def config_body(settings)
        <<~CONFIG
          # The config of roma server, made by roma new. Run the server in this
          # directory by
          #   roma server ADDRESS --config config.rb
          # The paths are from the directory where the server runs. The other
          # settings and their defaults are in roma/configuration.rb.
          Roma.configure do |config|
            config.name = '#{settings.name}'
            config.port = #{settings.port}

            config.storage.engine = #{settings.storage.engine.inspect}
            config.storage.path = 'data'
            config.routing.path = 'routing'
            config.log.path = 'log'
            config.write_behind.path = 'wb'
            config.command_plugin_path = 'command_plugins'

            # The file that the server writes its pid to. Give each node its
            # own file, such as by roma server --pid-file.
            # config.pid_file = 'roma.pid'
          end
        CONFIG
      end

      def gemfile_body(engine, dev)
        roma = dev ? "gem 'roma', path: '#{ROMA_ROOT}'" : "gem 'roma', '~> #{Roma::VERSION}'"
        gems = [roma]
        gems << "gem 'roma-storage-#{engine}'" unless engine == :hash
        "source 'https://rubygems.org'\n\n#{gems.join("\n")}\n"
      end
    end
  end
end
