# Summarizes the output of macOS's sample(1): for each thread, how its time
# splits into kinds of work, and the functions where it runs most.
#
#   ruby benchmark/sample_report.rb SAMPLE_OUTPUT
#
# sample(1) takes the stacks of all the threads every millisecond, whether
# they run or wait, so the shares are of the time, not of the CPU time.
module SampleReport
  # The kinds of work, in the order of the report. A sample is of the first
  # kind whose test its leaf function and its stack pass.
  KINDS = {
    'waiting for events' => ->(leaf, stack) { leaf.match?(/\A(__select|kevent|poll)\b/) && stack.include?('Select') },
    'waiting for the GVL' => lambda { |leaf, stack|
      leaf.start_with?('__psynch_cvwait') && stack.include?('thread_sched_to_running')
    },
    'blocked' => ->(leaf, _) { leaf.match?(/\A(__psynch_cvwait|__psynch_mutexwait|__select|kevent|poll)\b/) },
    'socket I/O' => ->(leaf, _) { leaf.match?(/\A(read|readv|write|writev|recvfrom|sendto|sendmsg)\b/) },
    'GC' => ->(_, stack) { stack.match?(/\bgc_|garbage_collect/) },
    'other system calls' => ->(leaf, _) { leaf.include?('(in libsystem_kernel.dylib)') },
    'running' => ->(_, _) { true }
  }.freeze

  # The samples of a thread by kind and by leaf function.
  class Thread
    attr_reader :name, :samples, :kinds, :leaves

    def initialize(name, samples)
      @name = name
      @samples = samples
      @kinds = Hash.new(0)
      @leaves = Hash.new(0)
    end

    # Adds +count+ samples whose stack is +frames+, from the root to the leaf.
    def add(frames, count)
      leaf = frames.last
      stack = frames.join(' > ')
      @kinds[KINDS.find { |_, test| test.call(leaf, stack) }.first] += count
      @leaves[leaf.sub(/ \+ [\d,]+.*\z/, '')] += count
    end

    # Whether the thread did more than wait.
    def busy?
      @kinds['blocked'] < @samples * 0.99
    end

    def share(kind)
      100.0 * @kinds[kind] / @samples
    end
  end

  module_function

  # The threads in +text+, the output of sample(1). Each line of its call
  # graph is a frame with the samples under it, indented under its caller,
  # so a frame's own samples are those that its callees don't have.
  def parse(text)
    threads = []
    stack = [] # [indent, frame, own samples]
    text.each_line do |line|
      break if line.start_with?('Total number in stack')

      m = line.chomp.match(/\A([ +!:|]*)(\d+) (.*)\z/) or next
      indent = m[1].size
      samples = m[2].to_i
      frame = m[3].sub(/\s+\[0x\h+.*\z/, '').strip
      pop(threads.last, stack, indent)
      if frame.start_with?('Thread_')
        threads << Thread.new(thread_name(frame), samples)
        next
      end
      next if threads.empty?

      stack.last[2] -= samples if stack.any?
      stack << [indent, frame, samples]
    end
    pop(threads.last, stack, 0)
    threads
  end

  # The main thread, or where Ruby named or started a thread, such as
  # "async_event.rb:25", from "Thread_123: async_event.rb:25".
  def thread_name(frame)
    return 'main' if frame.include?('com.apple.main-thread')

    name = frame.sub(/\AThread_\d+:?\s*/, '')
    name.empty? ? frame : name
  end

  # Pops the frames at +indent+ and deeper, and adds their own samples.
  def pop(thread, stack, indent)
    while stack.any? && stack.last[0] >= indent
      frames = stack.map { |frame| frame[1] }
      own = stack.pop[2]
      thread.add(frames, own) if own.positive?
    end
  end

  # A Markdown report of the busy threads in +text+.
  def report(text, functions: 15)
    table = ["| thread | samples | #{KINDS.keys.join(' | ')} |", "|---|--:|#{'--:|' * KINDS.size}"]
    details = []
    parse(text).select(&:busy?).each do |t|
      shares = KINDS.keys.map { |kind| format('%.1f%%', t.share(kind)) }
      table << "| #{t.name} | #{t.samples} | #{shares.join(' | ')} |"
      details << '' << "#{t.name}: the functions where it was" << '' << '```'
      t.leaves.max_by(functions, &:last).each do |leaf, samples|
        details << format('%6.1f%%  %s', 100.0 * samples / t.samples, leaf)
      end
      details << '```'
    end
    lines = table + details
    lines.join("\n") << "\n"
  end
end

puts SampleReport.report(File.read(ARGV.fetch(0))) if $PROGRAM_NAME == __FILE__
