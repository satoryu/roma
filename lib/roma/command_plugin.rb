module Roma
  module CommandPlugin
    # ROMA's own plugins that every node has. debug and test are
    # not here, since eval runs any Ruby code; require them from a file in the
    # plugin directory to use them.
    BUNDLED = %w(storage alist map mapcount gui).freeze

    # An expire time that never comes.
    NEVER_EXPIRES = 0x7fffffff

    @@plugins = []
    def self.plugins
      @@plugins.dup
    end

    def self.included(mod)
      @@plugins << mod
    end

    # The plugin files in +dir+: its *.rb files, in the order of their names.
    # Files in its subdirectories are not, so they can hold what the plugins
    # require.
    def self.files(dir)
      Dir.glob('*.rb', base: dir).sort.map { |file| File.join(File.expand_path(dir), file) }
    end

    # Requires the bundled plugins, then the plugin files in +dir+, and returns
    # what it required. A plugin in +dir+ is included later, so its commands
    # win over the bundled ones of the same names.
    def self.require_all(dir)
      paths = BUNDLED.map { |name| "roma/command_plugin/#{name}" } + files(dir)
      paths.each { |path| require path }
    end
  end
end
