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

  # A trap mustn't do the work itself, so it wakes a thread.
  def self.run
    require 'stackprof' if STACKPROF
    r, w = IO.pipe
    Signal.trap(:USR2) { w.write_nonblock('.') }
    Thread.new do
      count = 0
      gc = nil
      while r.read(1)
        if gc
          StackProf.stop if STACKPROF
          count += 1
          write(count, gc)
          gc = nil
        else
          gc = GC.stat.slice(*GC_KEYS)
          StackProf.start(mode: STACKPROF, interval: INTERVALS.fetch(STACKPROF), raw: true) if STACKPROF
        end
      end
    end
  end

  # Writes N.dump before N.json, which tells that both are there.
  def self.write(count, gc_before)
    path = File.join(DIR, count.to_s)
    StackProf.results("#{path}.dump") if STACKPROF
    after = GC.stat
    File.write("#{path}.tmp", JSON.generate(gc_before.to_h { |key, before| [key, after[key] - before] }))
    File.rename("#{path}.tmp", "#{path}.json")
  end
end

SetGetProfiler.run
