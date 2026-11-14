require 'digest/sha1'
require 'timeout'
require 'roma/async_message'
require 'roma/configuration'
require 'roma/async_event/vnode_transfer'
require 'roma/async_event/storage_maintenance'
require 'roma/async_event/log_gathering'

module Roma
  module AsyncEvent
    include VnodeTransfer
    include StorageMaintenance
    include LogGathering

    @@async_queue = Queue.new

    def self.queue
      @@async_queue
    end

    def start_async_event_loop
      @async_thread = Thread.new do
        async_event_loop
      end
      @async_thread[:name] = __method__
    rescue StandardError => e
      @log.error("#{e}\n#{$ERROR_POSITION}")
    end

    private

    def stop_async_event_loop
      count = 0
      while @@async_queue.empty? == false && count < 100
        count += 1
        sleep 0.1
      end
      @async_thread.exit
    end

    def async_event_loop
      loop do
        while msg = @@async_queue.pop
          if send("asyncev_#{msg.event}", msg.args)
            msg.callback.call(msg, true) if msg.callback
          elsif msg.retry?
            t = Thread.new do
              msg.wait
              msg.incr_count
              @@async_queue.push(msg)
            end
            t[:name] = __method__
          else
            @log.error("async event retry out:#{msg.inspect}")
            msg.callback.call(msg, false) if msg.callback
          end
        end
      end
    rescue StandardError => e
      @log.error("#{e}\n#{$ERROR_POSITION}")
      retry
    end

    def asyncev_broadcast_cmd(args)
      @log.debug("#{__method__} #{args.inspect}")
      cmd, node_ids, tout = args
      t = Thread.new do
        async_broadcast_cmd("#{cmd}\r\n", node_ids, tout)
      end
      t[:name] = __method__
      true
    end

    def asyncev_redundant(args) = send_redundant('rset', args)
    def asyncev_zredundant(args) = send_redundant('rzset', args)

    def asyncev_rdelete(args)
      node_id, hash_name, k, clock = args
      @log.debug("#{__method__} #{args.inspect}")
      unless @routing_table.nodes.include?(node_id)
        @log.warn("async rdelete failed:#{node_id} does not found in routing table.#{k}\e#{hash_name} #{clock}")
        return true # no retry
      end
      res = async_send_cmd(node_id, "rdelete #{k}\e#{hash_name} #{clock}\r\n", 10)
      unless res
        @log.warn("async redundant failed:#{k}\e#{hash_name} #{clock} -> #{node_id}")
        return false # retry
      end
      true
    end

    # Runs the block in a thread named +name+, and logs an error that it
    # raises. Returns the thread.
    def start_thread(name)
      t = Thread.new do
        yield
      rescue StandardError => e
        @log.error("#{name}:#{e.inspect} #{$ERROR_POSITION}")
      end
      t[:name] = name
      t
    end

    # The process that changes the routing and is running: :join, :recover
    # or :balance, or nil.
    def running_process
      if @stats.run_join then :join
      elsif @stats.run_recover then :recover
      elsif @stats.run_balance then :balance
      end
    end

    # Sends a value to a replica with +command+, rset or rzset for a
    # compressed value. Returns false to retry later.
    def send_redundant(command, args)
      node_id, hash_name, k, d, clock, expire_time, v = args
      @log.debug("#{__method__} #{args.inspect}")
      request = "#{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{v.length}"
      unless @routing_table.nodes.include?(node_id)
        @log.warn("async #{command} failed:#{node_id} does not found in routing table.#{request}")
        return true # no retry
      end
      res = async_send_cmd(node_id, "#{command} #{request}\r\n#{v}\r\n", 10)
      if res.nil? || res.start_with?('ERROR')
        @log.warn("async #{command} failed:#{request} -> #{node_id}")
        return false # retry
      end
      true
    end
  end
end
