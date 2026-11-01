require 'roma/stats'

module Roma
  module WriteBehind
    class FileWriter

      attr_accessor :shift_size

      def initialize(path, shift_size, log)
        @stats = Roma::Stats.instance
        path.chop! if path[-1]=='/'
        @path = path
        @log = log
        @fdh = {} # file handle hash
        @fnh = {} # file name hash
        @do_write = false
        @shift_size = shift_size
        @total_size = Hash.new(0)
        @rottime = Time.now
      end

      def get_stat
        ret = {}
        ret['write-behind.path'] = File.expand_path(@path)
        ret['write-behind.shift_size'] = @shift_size
        ret['write-behind.do_write'] = @do_write
        @fdh.each{|hash_name,fname|
          ret["write-behind[#{hash_name}].path"] = File.expand_path(fname)
          ret["write-behind[#{hash_name}].size"] = @total_size[hash_name]
        }
        ret
      end

      def write(hash_name, cmd, key, val)
        @do_write = true
        t = Time.now
        if @total_size[hash_name] >= @shift_size || t >= @rottime
          @do_write = false
          rotate(hash_name)
        end

        fd = @fdh[hash_name]
        unless fd
          fd = openfile(hash_name)
          @log.info("WriteBehind file has been created: [#{@fnh[hash_name]}]")
          @total_size[hash_name] = 0
        end
        klen = key.length
        val = val.to_s
        vlen = val.length
        size = fd.write([t.to_i, cmd, klen, key, vlen, val].pack("NnNa#{klen}Na#{vlen}"))
        @total_size[hash_name] += size
#        @log.debug("WriteBehind:hash_name=#{hash_name} cmd=#{cmd} key=#{key} val=#{val} total_size=#{@total_size}")
      ensure
        @do_write = false
      end

      def rotate(hash_name)
        @log.info("WriteBehind:rotate #{hash_name}")
        fd_old = @fdh[hash_name]
        unless fd_old
          @log.info("WriteBehind:rotate #{hash_name} not opend")
          return false
        end
        @fdh.delete(hash_name)
        @fnh.delete(hash_name)
        sleep 0.01 while @do_write
        fd_old.close
        @log.info("WriteBehind:rotate succeed")
        true
      end

      def openfile(hash_name)
        t = Time.now
        path = "#{@path}/#{@stats.my_node_id}/#{hash_name}/#{t.strftime('%Y%m%d')}"
        mkdir(path)
        # set a next rotation time
        @rottime = Time.local(t.year,t.month,t.day,0,0,0) + 24 * 60 * 60

        max = -1
        Dir::glob("#{path}/*.wb").each{|f|
          if /\D(\d+).wb$/ =~ f
            max = $1.to_i if $1.to_i > max
          end
        }
        fname = "#{path}/#{max + 1}.wb"
        fd = open(fname,'wb')
        @fnh[hash_name] = fname
        @fdh[hash_name] = fd
      end

      def wb_get_path(hash_name)
        File.expand_path("#{@path}/#{@stats.my_node_id}/#{hash_name}")
      end

      def get_current_file_path(hash_name)
        @log.info("WriteBehind:get_current_file_path #{hash_name}")
        unless @fnh[hash_name]
          @log.info("WriteBehind:get_current_file_path #{hash_name} not opend")
          return nil
        end
        File.expand_path("#{@fnh[hash_name]}")
      end

      def close_all
        @fdh.each_value{|fd| fd.close }
      end

      def mkdir(path)
        pbuf = +''
        path.split('/').each{|p|
          pbuf << p
          begin
            Dir::mkdir(pbuf) unless File.exist?(pbuf)
          rescue
          end
          pbuf << '/'
        }
      end

    end # class FileWriter
  end # module WriteBehind
end # module Roma
