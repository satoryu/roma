require 'roma/logging/rlogger'

module Roma
  # The settings of roma server. A config file sets them in Roma.configure:
  #
  #   Roma.configure do |config|
  #     config.port = 11211
  #     config.log.level = :info
  #     config.storage.engine = :dbm
  #   end
  #
  # Every setting has a default, and a wrong value raises Configuration::Error.
  class Configuration
    class Error < StandardError; end

    # A group of settings, such as config.log. A subclass declares them by
    # setting and group.
    class Group
      BOOLEAN = [true, false].freeze

      # Declares a setting with its default. The value must be one of +one_of+,
      # or of a class in +type+, or else +check+ returns false for it.
      def self.setting(name, default, type: nil, one_of: nil, check: nil)
        settings[name] = default
        attr_reader name

        define_method("#{name}=") do |value|
          valid = if one_of
                    one_of.include?(value)
                  else
                    Array(type).any? { |t| t === value } && (check.nil? || check.call(value))
                  end
          unless valid
            expected = one_of ? "one of #{one_of.map(&:inspect).join(', ')}" : "a valid #{Array(type).join(' or ')}"
            raise Error, "#{path_of(name)} should be #{expected}: #{value.inspect}"
          end
          instance_variable_set("@#{name}", value)
        end
      end

      # Declares a group of settings in this group.
      def self.group(name, klass)
        groups[name] = klass
        attr_reader name
      end

      def self.settings
        @settings ||= {}
      end

      def self.groups
        @groups ||= {}
      end

      # +prefix+ is the path to this group, such as "connection.pool".
      def initialize(prefix = nil)
        @prefix = prefix
        self.class.settings.each do |name, default|
          instance_variable_set("@#{name}", default.frozen? ? default : default.dup)
        end
        self.class.groups.each do |name, klass|
          instance_variable_set("@#{name}", klass.new(path_of(name)))
        end
      end

      # The settings in a Hash by their paths, such as "log.level".
      def to_h
        h = self.class.settings.keys.to_h { |name| [path_of(name), public_send(name)] }
        self.class.groups.each_key { |name| h.merge!(public_send(name).to_h) }
        h
      end

      private

      def path_of(name)
        @prefix ? "#{@prefix}.#{name}" : name.to_s
      end
    end

    class Routing < Group
      CHURNBASED_ROUTING_TABLE = 'Roma::Routing::ChurnbasedRoutingTable'.freeze

      setting :path, '.', type: String
      # Roma::Routing::ChurnbasedRoutingTable or a subclass of it, or nil for
      # ChurnbasedRoutingTable. The server needs its failover and events.
      setting :table_class, nil, type: [Class, NilClass],
                                 check: ->(v) { v.nil? || v.ancestors.any? { |c| c.name == CHURNBASED_ROUTING_TABLE } }
      # Replaces the host names in the routing table that a client gets:
      # { '192.168.1.0/24' => { regexp: 'host1', replace: '192.168.1.11' } }
      setting :node_id_substitutions, {}, type: Hash
      # What to do when the data of a vnode is lost.
      setting :lost_action, :auto_assign, one_of: %i(no_action auto_assign shutdown)
      setting :auto_recover, false, one_of: BOOLEAN
      # The failures to a node, before it is taken as down.
      setting :failure_count_threshold, 15, type: Integer
      # Seconds in which another failure doesn't count up.
      setting :failure_count_gap, 0, type: Numeric
      setting :event_limit_line, 1000, type: Integer
    end

    class Log < Group
      setting :path, '.', type: String
      setting :level, :info, one_of: Roma::Logging::RLogger::Severity::LEVELS.keys
      # The files to keep, or 'daily', 'weekly' or 'monthly'.
      setting :shift_age, 10, type: [Integer, String]
      setting :shift_size, 1024 * 1024 * 10, type: Integer
      setting :stream_show_wait, 0.001, type: Numeric
    end

    class Pool < Group
      # Seconds to keep a connection in the pool. It should be less than
      # connection.expire_time.
      setting :expire_time, 30, type: Numeric
      setting :max, 5, type: Integer
      # Seconds to wait for a node to connect, or to answer.
      setting :timeout, 10, type: Numeric, check: ->(v) { v.positive? }
    end

    class EventMachinePool < Group
      setting :expire_time, 30, type: Numeric
      setting :max, 15, type: Integer
      # Seconds to wait for a node to connect, or to answer.
      setting :timeout, 10, type: Numeric, check: ->(v) { v.positive? }
    end

    class Connection < Group
      setting :use_epoll, true, one_of: BOOLEAN
      setting :descriptor_table_size, 4096, type: Integer
      # Like MaxStartups of sshd_config: 'start:rate:full', where start is
      # less than full and rate is up to 100.
      setting :continuous_limit, '200:30:300', type: String, check: lambda { |v|
        (m = v.match(/\A(\d+):(\d+):(\d+)\z/)) && m[2].to_i <= 100 && m[1].to_i < m[3].to_i
      }
      # Seconds to keep an accepted connection, or 0 for ever.
      setting :expire_time, 0, type: Numeric
      # The longest request line in bytes. A longer one closes the connection.
      setting :max_line_length, 1024 * 1024, type: Integer, check: ->(v) { v.positive? }
      setting :dns_caching, false, one_of: BOOLEAN
      group :pool, Pool
      group :event_machine_pool, EventMachinePool
    end

    class Storage < Group
      # The name of a storage, such as :dbm of the gem roma-storage-dbm, or a
      # storage class.
      setting :engine, :hash, type: [Symbol, Class], check: ->(v) { v.is_a?(Class) || v.match?(/\A[a-z][a-z0-9_]*\z/) }
      setting :path, '.', type: String
      # The files that a storage is divided into.
      setting :division_count, 10, type: Integer, check: ->(v) { v.positive? }
      setting :option, '', type: [String, NilClass]
      # What to do when the storage fails.
      setting :exception_action, :no_action, one_of: %i(no_action shutdown)
      # Seconds to keep deleted and expired keys.
      setting :delete_mark_expire_time, 60 * 60 * 24 * 5, type: Integer
      setting :clean_up_interval, 60 * 5, type: Integer
      # The largest value in bytes that a node takes, also after inflating
      # the value of rzset.
      setting :max_value_size, 16 * 1024 * 1024, type: Integer, check: ->(v) { v.positive? }

      # The storage class of engine. A name such as :dbm requires
      # roma/storage/dbm of the gem roma-storage-dbm, and is the class in it
      # named like DbmStorage, in any case. :hash is in roma-storage, which
      # ROMA needs. Raises Error if the file or the class is missing.
      def engine_class
        return engine if engine.is_a?(Class)

        file = "roma/storage/#{engine}"
        begin
          require file
        rescue LoadError => e
          # A LoadError of another file, which the storage requires, is raised.
          raise unless e.path == file

          gem = "roma-storage-#{engine}"
          raise Error, "storage.engine #{engine.inspect} needs #{gem}. Install it by gem install #{gem}."
        end

        class_name = "#{engine.to_s.split('_').map(&:capitalize).join}Storage"
        name = Roma::Storage.constants.find { |c| c.to_s.casecmp?(class_name.delete('_')) }
        raise Error, "#{file} has no storage class such as Roma::Storage::#{class_name}." unless name

        Roma::Storage.const_get(name)
      end

      # A storage of engine with these settings, for the files in
      # +storage_path+ and the vnodes +vn_list+. It isn't opened.
      def build(storage_path, vn_list)
        engine = engine_class
        engine.new.tap do |st|
          st.storage_path = storage_path
          st.vn_list = vn_list
          st.st_class = engine
          st.divnum = division_count
          st.option = option
        end
      end
    end

    class DataCopy < Group
      setting :stream_copy_wait, 0.001, type: Numeric
    end

    class WriteBehind < Group
      setting :path, './wb', type: String
      setting :shift_size, 1024 * 1024 * 10, type: Integer
      # The commands to write behind, by their numbers: { set: 1, delete: 2 }
      setting :command_map, {}, type: Hash
    end

    class Redundant < Group
      # The data bigger than this is compressed for the redundancy, or 0 for never.
      setting :compression_threshold, 0, type: Integer
    end

    class Settings < Group
      setting :name, 'ROMA', type: String
      setting :port, 12_000, type: Integer, check: ->(v) { (1..65_535).cover?(v) }
      # The address that the server listens on, such as '0.0.0.0' for all,
      # or nil for the IPv4 address of the host of the node.
      setting :bind_address, nil, type: [String, NilClass]
      # The directory of the command plugins. The server requires the *.rb files in it.
      setting :command_plugin_path, './command_plugins', type: String
      # The file that the server writes its pid to, or nil for none.
      setting :pid_file, nil, type: [String, NilClass]
      # The umask of the server, for the files that it makes: the storages,
      # the logs, write-behind and the routing. 0o027 lets the group read
      # them and the others nothing; nil keeps that of the process.
      setting :umask, 0o027, type: [Integer, NilClass], check: ->(v) { v.nil? || (0..0o777).cover?(v) }
      group :routing, Routing
      group :log, Log
      group :connection, Connection
      group :storage, Storage
      group :data_copy, DataCopy
      group :write_behind, WriteBehind
      group :redundant, Redundant
    end
  end

  # The settings of roma server.
  def self.config
    @config ||= Configuration::Settings.new
  end

  # Yields the settings to change them.
  def self.configure
    yield config
  end

  # Puts the settings back to the defaults.
  def self.reset_config
    @config = nil
  end

  # Puts the settings back to the defaults, and runs the config file at
  # +path+. Raises Configuration::Error if the file is of the old format,
  # which defines the constants of Roma::Config.
  def self.load_config(path)
    reset_config
    load path
    return unless Roma.const_defined?(:Config, false)

    raise Configuration::Error, "#{path} defines Roma::Config, which ROMA 2.0 doesn't read. " \
                                'Set the settings in Roma.configure instead. See ChangeLog.md.'
  end
end
