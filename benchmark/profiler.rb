# Loaded into a ROMA node by set_get.rb --profile. The first USR2 starts
# StackProf, the next stops it and writes the samples to N.dump in
# SET_GET_PROFILE_DIR, and so on.
require 'stackprof'

module SetGetProfiler
  DIR = ENV.fetch('SET_GET_PROFILE_DIR')

  # A trap mustn't do the work itself, so it wakes a thread.
  def self.run
    r, w = IO.pipe
    Signal.trap(:USR2) { w.write_nonblock('.') }
    Thread.new do
      count = 0
      while r.read(1)
        if StackProf.running?
          StackProf.stop
          count += 1
          path = File.join(DIR, "#{count}.dump")
          StackProf.results("#{path}.tmp")
          File.rename("#{path}.tmp", path)
        else
          StackProf.start(mode: :cpu, interval: 200, raw: true)
        end
      end
    end
  end
end

SetGetProfiler.run
