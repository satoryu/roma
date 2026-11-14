module Roma
  # The file that a server writes its pid to, such as by roma server
  # --pid-file.
  class PidFile
    attr_reader :path

    def initialize(path)
      @path = path
    end

    # Why the server can't take the file, or nil: the file has the pid of a
    # running process, such as another server, or can't be written. A file
    # of a process that is gone can be taken.
    def error
      if File.exist?(@path)
        pid = File.read(@path).to_i
        return "#{@path} has the pid #{pid}, which is running." if pid.positive? && alive?(pid)
      end
      return if File.exist?(@path) ? File.writable?(@path) : File.writable?(File.dirname(@path))

      "#{@path} can't be written."
    end

    def write
      File.write(@path, "#{Process.pid}\n")
    end

    # Removes the file if it has the pid of this process: another server may
    # have overwritten it.
    def remove
      return unless File.exist?(@path) && File.read(@path).to_i == Process.pid

      File.delete(@path)
    end

    private

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end
