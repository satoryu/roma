require 'yaml'
require 'fileutils'
require 'roma/configuration'

module Roma
  module Tools

    class ConfigCreator
      TREE_TOP = "menu"
      BNUM_COEFFICIENT = 2 #reccomend1-4.
      DIVIDED_FILES = 10
      REDUNDANCY = 2
      DEFAULT_ROMA_CONNECTION = 12
      RUBY_CONNECTION = 10
      JAVA_CONNECTION = 30
      PHP_CONNECTION = 256
      KB = 1024
      GB = 1024 * 1024 * 1024
      OS_MEMORY_SIZE = 1 * GB
      END_MSG = ["exit", "quit", "balse"]

      class Base
        attr_accessor :all

        def initialize
          @all = YAML.load <<-YAML
          menu:
            name:
            path_name: menu
            message: Please select by number.
            choice:
              - Select storage
              - Calculate File Descriptor
              - Save
            next:
              - storage
              - language
              - save

          storage:
            name: selected_storage
            path_name: storage
            message: Which storage will you use?
            choice:
              - Ruby Hash
              - Groonga
            default: 1
            next:
              - menu
              - memory
          memory:
            name: memory_size_GB
            path_name:
            float_flg: on
            message: How big memory size in 1 server? Please measure in GB.
            default: 0.6
            next: process
          process:
            name: process_num
            path_name:
            message: How many run ROMA process per machine?
            default: 2
            next: server
          server:
            name: server_num
            path_name:
            message: How many machine run as ROMA server?
            default: 1
            next: data
          data:
            name: data_num
            path_name:
            message: How many data will you store?
            default: 10000
            next: menu

          language:
            name: client_language
            path_name:
            message: Please select programming language of client by number.
            choice:
              - Ruby
              - Java
              - PHP
            default: 3
            next:
              - fd_server
              - fd_server
              - fd_server
          fd_server:
            name: server_num
            path_name: FileDescriptor
            message: How many machine run as ROMA server?
            default: 1
            next: fd_client
          fd_client:
            name: client_num 
            path_name:
            message: How many machine run as ROMA client?
            default: 1
            next: menu

          save: END

          YAML
        end

        def keys
          all.keys
        end

        def [](s)
          all[s]
        end

        def print_question(key, out)
          target = all[key]
          #print question
          out.print "#{target["message"]}\n"
          if target.key?("choice")
            target["choice"].each_with_index do |k, i|
              out.print "[#{i + 1}] #{k}\n"
            end
          end
        end

        def next (key, input)
          target = all[key]["next"]

          if target.class == Array
            return target[input.to_i - 1]
          else
            return target
          end
        end
      end

      class Input
        module InputReadline
          def get_line
            return Readline.readline("> ", false)
          end
        end

        module InputSimple
          def get_line
            print ">"
            return $stdin.gets&.chomp
          end
        end

        def initialize
          begin
            require "readline"
          rescue LoadError
            self.extend InputSimple
            return
          end
          self.extend InputReadline
        end
      end

      class ConfigStatus
        attr_accessor :name, :value, :print, :default_value
        def initialize(hash, input)
          @name = hash["name"]
          @value = input
          @print = true
        end
      end

      class Box
        def self.print_edge(width, out)
          out.print "+"
            width.times { out.print "-" }
          out.print "+\n"
        end

        def self.print_with_box(arg, out = $stdout)
          return if arg.count == 0

          if arg.class == Hash
            strs = Array.new
            arg.each do |k, v|
               strs << "#{k}: #{arg[k]}"
            end
            arg = strs
          end

          width = max_length(arg) + 1
          print_edge(width, out)

          arg.each do |s|
            out.print "|#{s}"
            (width - s.length).times do
              out.print " "
            end
            out.print "|\n"
          end

          print_edge(width, out)
        end

        private

        def self.max_length(arg)
          max = 0
          arg.each do |s|
            max = s.length if s.length > max
          end
          max
        end
      end

      class Calculate
        def self.get_bnum(res)
          res["server"] = res["fd_server"] if !res["server"]
          ans = res["data"].value.to_i * BNUM_COEFFICIENT * REDUNDANCY / res["server"].value.to_i / DIVIDED_FILES
          return ans
        end

        def self.get_xmsize_max(res)
          ans = (res["memory"].value.to_f * GB - OS_MEMORY_SIZE) / res["process"].value.to_i / DIVIDED_FILES
          if ans <= 0
            ans = res["memory"].value.to_f * GB / 2 / res["process"].value.to_i / DIVIDED_FILES
          end
          ans = ans.to_i
          return ans
        end

        def self.get_fd(res)
          res["fd_server"] = res["server"] if !res["fd_server"]
          res["fd_server"].value.to_i * connection_num(res) + (res["fd_client"].value.to_i- 1) * DEFAULT_ROMA_CONNECTION * 2
        end

        def self.connection_num(res)
          case res["language"].value
            when "Ruby"
              connection = RUBY_CONNECTION
            when "Java"
              connection = JAVA_CONNECTION
            when "PHP"
              connection = PHP_CONNECTION
          end

          return connection
        end
      end

      # +input+ gives the lines typed in, +out+ is where the questions go, and
      # +path+ is the file to make.
      def initialize(input: Input.new, out: $stdout, path: File.expand_path("config.rb"))
        @input = input
        @out = out
        @path = path
      end

      # Asks the questions and makes the file. With +mode+ :with_menu, the menu
      # is shown to choose what to set; otherwise all the questions are asked
      # in turn.
      def run(mode = :no_menu)
        # confirming overwrite
        if File.exist?(@path)
          print("Config.rb already exist in current directory. \nWill you overwrite?[y/n]")
          if @input.get_line != "y"
            puts "config.rb  were not created!"
            return
          end
        end

        @base = Base.new
        @results = Hash::new
        @next_hash = TREE_TOP

        defaults = Roma::Configuration::Settings.new.to_h
        @defaults = %w(storage.engine storage.option).to_h { |key| [key, defaults[key]] }
        create(mode)
      end

      def create(mode)
        skip = skip_menu!(mode)

        while true
          clear_screen

          skip.call if @next_hash == "menu" || @next_hash == "server" || @next_hash == "fd_server"
          break if end?(@base[@next_hash])
          puts "if you doesn't input anything, default value is set."
          Box.print_with_box(@defaults, @out)
          print_status(@results)
          @base.print_question(@next_hash, @out)
          input = get_input(@base[@next_hash])

          # if specific words(balse, exit, quit) was inputed, roma config create was finished.
          if END_MSG.include?(input)
            puts "config.rb  were not created!"
            break

          else
            @results = store_result(@results, @base, @next_hash, input)
            @next_hash = @base.next(@next_hash, input)
          end
        end
      end

      def clear_screen
        print "\e[H\e[2J"
      end

      def skip_menu!(menu)
        # in case of "-m" or "--with_menu" option was used
        if menu == :with_menu
          return Proc.new do
            if @next_hash == "server" && @results["fd_server"]
              @next_hash = @base["server"]["next"]
            elsif @next_hash == "fd_server" && @results["server"]
              @next_hash = "fd_client"
            end
          end
        end

        # in case of "-m" or "--with_menu" option was NOT used
        i = 0
        return Proc.new do
          if @next_hash == "menu"
            @next_hash = @base["menu"]["next"][i]
            i += 1
          elsif @next_hash == "server" && @results["fd_server"]
            @next_hash = @base["server"]["next"]
          elsif @next_hash == "fd_server" && @results["server"]
            @next_hash = "fd_client"
          end
        end
      end

      #judge whether data inputting finish or not
      def end?(s)
        if s == "END"
          save_data(@results)
          true
        end
      end

      def print_status(results)
        strs = Array.new
        results.each_value do |v|
          strs << "#{v.name} : #{v.value}"
        end
        Box.print_with_box(strs, @out)
      end

      def get_input(hash)
        input = ""

        while !correct_in?(hash,input)
          # The end of the input quits.
          input = @input.get_line || END_MSG.first
          if input == ""
            #set defaults value
            input = hash["default"]
          end
        end

        input
      end

      def correct_in?(hash,input)
        if END_MSG.include?(input)
          return true
        end

        if hash.key?('choice')
          if hash['choice'].count >= input.to_i && input.to_i > 0
            return true
          end
        else
          if hash["float_flg"]
            if 0 < input.to_f
              return true
            end
          else
            if 0 < input.to_i
              return true
            end
          end
        end

        return false
      end

      def store_result(results, base, hash, input)
        target = base[hash]

        return results if !target["name"]

        if target.key?("choice")
          results[hash] = ConfigStatus.new(target, target["choice"][input.to_i - 1])
        else
          results[hash] = ConfigStatus.new(target, input)
        end

        return results
      end

      # Makes config.rb from the answers.
      def save_data(res)
        results = @defaults.dup
        if res.key?("storage")
          case res["storage"].value
          when "Ruby Hash"
            results["storage.engine"] = :hash
            results["storage.option"] = ""
          when "Groonga"
            bnum = Calculate.get_bnum(res)
            bnum = 5000000 if bnum < 5000000
            xmsiz = Calculate.get_xmsize_max(res)
            results["storage.engine"] = :groonga
            results["storage.option"] = "bnum=#{bnum}\#xmsiz=#{xmsiz}\#opts=d#dfunit=10"
          end
        end

        if res.key?("language")
          fd = Calculate.get_fd(res)
          print "\r\nPlease set FileDescriptor bigger than #{fd}.\r\n\r\n" 
        end

        open(@path, "w") do |f|
          f.flock(File::LOCK_EX)
          f.puts config_body(results)
          f.truncate(f.tell)
          f.flock(File::LOCK_UN)
        end

        puts "Before"
        Box.print_with_box(@defaults.transform_values(&:inspect), @out)
        print "\r\nAfter\r\n"
        Box.print_with_box(results.transform_values(&:inspect), @out)
        print "\r\nconfig.rb has been made.\r\n"
        print "\r\nIf you need, change the paths of the log, the routing table, the storage, write-behind and the command plugins, and the other settings.\r\n\r\n"
      end

      # The config file with +settings+, which are the values by their paths
      # such as "storage.engine".
      def config_body(settings)
        defaults = Roma::Configuration::Settings.new
        lines = settings.map { |path, value| "  config.#{path} = #{value.inspect}" }
        paths = %w(log.path routing.path storage.path write_behind.path command_plugin_path).map do |path|
          "  # config.#{path} = #{path.split('.').inject(defaults) { |group, name| group.public_send(name) }.inspect}"
        end
        <<~CONFIG
          # The config of romad, made by roma config create. Run romad with it by
          #   roma server ADDRESS --config #{File.basename(@path)}
          # The other settings and their defaults are in roma/configuration.rb.
          Roma.configure do |config|
          #{lines.join("\n")}

          #{paths.join("\n")}
          end
        CONFIG
      end

      def print(*args)
        @out.print(*args)
      end

      def puts(*args)
        @out.puts(*args)
      end

    end # ConfigCreator
  end # module Tools
end # module Roma
