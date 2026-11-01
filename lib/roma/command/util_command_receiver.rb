require 'roma/messaging/con_pool'

module Roma
  module Command

    module UtilCommandReceiver

      def send_cmd(nid, cmd)
        con = get_connection(nid)
        con.send(cmd)
        res = con.gets
        if res == nil
          @routing_table.proc_failed(nid)
          return nil
        elsif res.start_with?("ERROR") == false
          @routing_table.proc_succeed(nid)
          return_connection(nid, con)
        end
        res.chomp
      rescue => e
        @routing_table.proc_failed(nid)
        @log.error("#{e}\n#{$@}")
        nil
      end

      def broadcast_cmd(cmd)
        res={}
        @routing_table.nodes.each{|nid|
          res[nid] = send_cmd(nid,cmd) if nid != @stats.my_node_id
        }
        res
      end

      def async_send_cmd(nid, cmd)
        con = Roma::Messaging::ConPool.instance.get_connection(nid)
        con.write(cmd)
        res = con.gets
        Roma::Messaging::ConPool.instance.return_connection(nid, con)
        if res
          res.chomp!
          @routing_table.proc_succeed(nid)
        else
          @routing_table.proc_failed(nid)
        end
        res
      rescue => e
        @routing_table.proc_failed(nid)
        @log.error("#{e}\n#{$@}")
        nil
      end

      def async_broadcast_cmd(cmd,without_nids=nil)
        without_nids=[@stats.my_node_id] unless without_nids
        res = {}
        @routing_table.nodes.each{ |nid|
          res[nid] = async_send_cmd(nid,cmd) unless without_nids.include?(nid)
        }
        res
      rescue => e
        @log.error("#{e}\n#{$@}")
        nil
      end

      # change to actual time for a memcached's expire time value
      def chg_time_expt(expire_time)
        if expire_time == 0
          expire_time = 0x7fffffff
        elsif expire_time < 2592000
          expire_time += Time.now.to_i
        end
        expire_time
      end

    end # module UtilCommandReceiver

  end # module Command
end # module Roma
