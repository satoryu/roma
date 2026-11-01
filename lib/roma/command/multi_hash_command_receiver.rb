require 'fileutils'
require 'roma/stats'
require 'roma/command/util_command_receiver'
require 'roma/command/definition'
require 'roma/configuration'

module Roma
  module Command

    module MultiHashCommandReceiver
      include Roma::Command::Definition

      # defhash <name>
      def_command_with_relay :defhash do |s|
        if s.length != 2
          "#{@default_hash_name}"
        else
          unless @storages.key?(s[1])
            raise(Roma::Command::Definition::ClientError,
                  "#{s[1]} does not find.")
          end
          @default_hash_name = s[1]
          "STORED"
        end        
      end

      # mounthash <name>
      def_command_with_relay :mounthash do |s|
        if s.length != 2
          raise(Roma::Command::Definition::ClientError,
                "usage:mounthash <name>")
        end
        if @storages.key?(s[1])
          raise(Roma::Command::Definition::ServerError,
                "#{s[1]} already mounted.")
        end
        # check a directory existence
        unless File.directory? "#{Roma.config.storage.path}/#{@stats.my_node_id}/#{s[1]}"
          raise(Roma::Command::Definition::ServerError,
                "#{s[1]} does not find.")
        end
        createhash(s[1], 'MOUNTED')
      end

      # umounthash <name>
      def_command_with_relay :umounthash do |s|
        if s.length != 2
          raise(Roma::Command::Definition::ClientError,
                "usage:umounthash <name>")
        end
        unless @storages.key?(s[1])
          raise(Roma::Command::Definition::ServerError,
                "#{s[1]} does not find.")
        end
        umounthash(s[1])
      end
            
      # createhash <name>
      def_command_with_relay :createhash do |s|
        if s.length != 2
          raise(Roma::Command::Definition::ClientError,
                "usage:createhash <name>")
        end
        createhash(s[1], 'CREATED')
      end

      # deletehash <name>
      def_command_with_relay :deletehash do |s|
        if s.length != 2
          raise(Roma::Command::Definition::ClientError,
                "usage:deletehash <name>")
        end
        deletehash(s[1])
      end

      # hashlist
      def ev_hashlist(s)
        send_data("#{@storages.keys.join ' '}\r\n")
      end

      def createhash(hname, msg)
        if @storages.key?(hname)
          return "SERVER_ERROR #{hname} already exists."
        end
        st = Roma.config.storage.engine_class.new
        st.storage_path = "#{Roma.config.storage.path}/#{@stats.my_node_id}/#{hname}"
        st.vn_list = @routing_table.vnodes
        st.divnum = Roma.config.storage.division_count
        st.option = Roma.config.storage.option
        @storages[hname] = st
        @storages[hname].opendb
        @log.info("createhash #{hname}")
        return msg
      rescue =>e
        @log.error("#{e} #{$@}")
        "NOT #{msg}"
      end
      private :createhash

      def deletehash(hname)
        ret = umounthash(hname)
        return ret if ret != 'UNMOUNTED'
        FileUtils.rm_rf "#{Roma.config.storage.path}/#{@stats.my_node_id}/#{hname}"
        @log.info("deletehash #{hname}")
        return "DELETED"
      rescue =>e
        @log.error("#{e}")
      end
      private :deletehash
      
      def umounthash(hname)
        if @default_hash_name == hname
          return "SERVER_ERROR default hash can't unmount."
        end
        unless @storages.key?(hname)
          return "SERVER_ERROR #{hname} does not exists."
        end
        st = @storages[hname]
        @storages.delete(hname)
        st.closedb
        "UNMOUNTED"
      end
      private :umounthash

    end # MultiHashCommandReceiver

  end # module Command
end # module Roma
