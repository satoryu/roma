require 'timeout'
require 'roma/messaging/connection_pool'
require 'roma/routing/routing_data'

module Roma
  # The commands that a server sends to the other nodes from its own
  # threads, such as AsyncEvent and ClusterMaintenance, through
  # Messaging::ConnectionPool. The commands of the connections send theirs
  # by Command::UtilCommandReceiver instead.
  module PeerCommand
    private

    # Takes the binary format, not the Marshal one, so that a node can't make
    # this one load any object.
    def fetch_routedump(node_id)
      received = receive_routing_dump(node_id, "routingdump bin\r\n")
      received && Routing::RoutingData.decode_binary(received)
    rescue StandardError
      nil
    end

    def receive_routing_dump(node_id, cmd)
      con = Messaging::ConnectionPool.instance.checkout(node_id)
      con.write(cmd)
      unless select [con], nil, nil, 1
        con.close
        return nil
      end
      len = con.gets
      if len.to_i <= 0
        con.close
        return nil
      end

      received = ''
      received += con.read(len.to_i - received.length) while received.length != len.to_i
      con.read(2)
      con.gets
      Messaging::ConnectionPool.instance.checkin(node_id, con)
      received
    rescue Exception
      nil
    end

    def async_send_cmd(node_id, cmd, tout = nil)
      con = res = nil
      if tout
        Timeout.timeout(tout) do
          con = Roma::Messaging::ConnectionPool.instance.checkout(node_id)
          unless con
            @routing_table.proc_failed(node_id) if @routing_table
            @log.error("#{__FILE__}:#{__LINE__}:#{node_id} connection refused,command is #{command_line(cmd)}.")
            return nil
          end
          con.write(cmd)
          res = con.gets
        end
      else
        con = Roma::Messaging::ConnectionPool.instance.checkout(node_id)
        unless con
          @routing_table.proc_failed(node_id) if @routing_table
          @log.error("#{__FILE__}:#{__LINE__}:#{node_id} connection refused,command is #{command_line(cmd)}.")
          return nil
        end
        con.write(cmd)
        res = con.gets
      end
      if res.nil?
        @routing_table.proc_failed(node_id) if @routing_table
        return nil
      elsif res.start_with?('ERROR') || res == "\r\n"
        # The reply may have more lines; see UtilCommandReceiver#send_cmd.
        con.close
      else
        @routing_table.proc_succeed(node_id) if @routing_table
        Roma::Messaging::ConnectionPool.instance.checkin(node_id, con)
      end
      res.chomp
    rescue Exception => e
      @routing_table.proc_failed(node_id) if @routing_table
      @log.error("#{__FILE__}:#{__LINE__}:#{e} #{$@}")
      @log.error("#{__FILE__}:#{__LINE__}:Send command failed that node-id is #{node_id}," \
                 "command is #{command_line(cmd)}.")
      nil
    end

    def async_broadcast_cmd(cmd, without_node_ids = nil, tout = nil)
      without_node_ids ||= [@stats.my_node_id]
      res = {}
      @routing_table.nodes.each do |node_id|
        res[node_id] = async_send_cmd(node_id, cmd, tout) unless without_node_ids.include?(node_id)
      end
      res
    rescue Exception => e
      @log.error("#{e}\n#{$@}")
      nil
    end

    # The first line of +cmd+, for the log: the value of a command such as
    # rset, which follows it, isn't logged.
    def command_line(cmd)
      cmd[/\A[^\r\n]*/]
    end
  end
end
