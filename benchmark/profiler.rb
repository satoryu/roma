# Loaded into a ROMA node by set_get.rb --profile. The first USR2 starts
# recording, the next stops it and writes N.json in SET_GET_PROFILE_DIR: how
# GC.stat changed. With SET_GET_STACKPROF, such as cpu or object, StackProf
# also runs in that mode and writes its samples to N.dump.
require 'json'

module SetGetProfiler
  DIR = ENV.fetch('SET_GET_PROFILE_DIR')
  STACKPROF = ENV.fetch('SET_GET_STACKPROF', nil)&.to_sym
  # The interval of each mode of StackProf: microseconds of CPU time, or
  # allocations.
  INTERVALS = { cpu: 200, wall: 200, object: 1 }.freeze
  GC_KEYS = %i(count minor_gc_count major_gc_count total_allocated_objects time).freeze

  # StackProf samples the thread that starts it, so the trap, which runs in
  # the main thread where the event loop handles the requests, starts and
  # stops it. A thread writes the files, which a trap mustn't do.
  def self.run
    require 'stackprof' if STACKPROF
    records = Queue.new
    gc = nil
    Signal.trap(:USR2) do
      if gc
        StackProf.stop if STACKPROF
        records << gc.to_h { |key, before| [key, GC.stat(key) - before] }
        gc = nil
      else
        gc = GC.stat.slice(*GC_KEYS)
        StackProf.start(mode: STACKPROF, interval: INTERVALS.fetch(STACKPROF), raw: true) if STACKPROF
      end
    end
    Thread.new do
      count = 0
      while (record = records.pop)
        count += 1
        write(count, record)
      end
    end
  end

  # Writes N.dump before N.json, which tells that both are there.
  def self.write(count, record)
    path = File.join(DIR, count.to_s)
    StackProf.results("#{path}.dump") if STACKPROF
    File.write("#{path}.tmp", JSON.generate(record))
    File.rename("#{path}.tmp", "#{path}.json")
  end
end

SetGetProfiler.run
