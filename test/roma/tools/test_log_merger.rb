require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/tools/log_merger'

class LogMergerTest < Test::Unit::TestCase
  include ToolTestHelper

  def setup
    super
    File.write(File.join(@dir, 'a.log'), <<~LOG)
      # Logfile created on 2026-01-01 00:00:00 by logger.rb
      I, [2026-01-01T00:00:01.000001 #1]  INFO -- : a1
      D, [2026-01-01T00:00:03.000001 #1] DEBUG -- : a2
      continued line of a2
      E, [2026-01-01T00:00:05.000001 #1] ERROR -- : a3
    LOG
    File.write(File.join(@dir, 'b.log'), <<~LOG)
      W, [2026-01-01T00:00:02.000001 #2]  WARN -- : b1
      I, [2026-01-01T00:00:04.000001 #2]  INFO -- : b2
    LOG
  end

  def merged(**)
    out = StringIO.new
    Roma::Tools::LogMerger.new(out: out).merge(%w(a.log b.log).map { |f| File.join(@dir, f) }, **)
    out.string.lines.map do |l|
      l[/\A(\w)\.log,.*: (\w+)$/] ? "#{::Regexp.last_match(1)}:#{::Regexp.last_match(2)}" : l.chomp
    end
  end

  # Each line is prefixed with its file. A line without a date belongs to
  # the line before.
  def test_merge_in_time_order
    assert_equal ['a:a1', 'b:b1', 'a:a2', 'continued line of a2', 'b:b2', 'a:a3'], merged
  end

  def test_whole_line
    out = StringIO.new
    Roma::Tools::LogMerger.new(out: out).merge([File.join(@dir, 'b.log')])
    assert_equal "b.log,W, [2026-01-01T00:00:02.000001 #2]  WARN -- : b1\nb.log,I, [2026-01-01T00:00:04.000001 #2]  INFO -- : b2\n",
                 out.string
  end

  data('TRACE' => ['TRACE', ['a:a1', 'b:b1', 'a:a2', 'continued line of a2', 'b:b2', 'a:a3']],
       'INFO' => ['INFO', ['a:a1', 'b:b1', 'b:b2', 'a:a3']],
       'WARN' => ['WARN', ['b:b1', 'a:a3']],
       'ERROR' => ['ERROR', ['a:a3']],
       'FATAL' => ['FATAL', []])
  def test_level(data)
    level, expected = data
    assert_equal expected, merged(level: level)
  end

  def test_period
    assert_equal ['b:b1', 'a:a2', 'continued line of a2', 'b:b2'],
                 merged(start_date: '20260101000002', end_date: '20260101000004')
  end

  # A date is filled up to the start or the end of the period it names.
  def test_period_by_a_prefix
    assert_equal ['a:a1', 'b:b1', 'a:a2', 'continued line of a2', 'b:b2', 'a:a3'],
                 merged(start_date: '2026', end_date: '20260101')
    assert_equal [], merged(start_date: '20260102')
    assert_equal [], merged(end_date: '2025')
  end
end
