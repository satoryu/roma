require 'test_helper'
require 'tmpdir'
require 'roma/logging/rlogger'

class RLoggerTest < Test::Unit::TestCase
  RLogger = Roma::Logging::RLogger

  def setup
    @dir = Dir.mktmpdir('roma_rlogger')
    @file = "#{@dir}/roma.log"
  end

  def teardown
    @logger&.close
    FileUtils.rm_rf(@dir)
  end

  # RLogger.new is private once the singleton is made.
  def logger(shift_age = 0, shift_size = 1_048_576)
    @logger = RLogger.send(:new, @file, shift_age, shift_size)
  end

  def logdev
    @logger.instance_variable_get(:@wrap_logger).instance_variable_get(:@logdev)
  end

  def files
    Dir.children(@dir).sort
  end

  def make_old
    File.utime(Time.now - 86_400 * 40, Time.now - 86_400 * 40, @file)
  end

  def test_levels
    logger
    @logger.level = RLogger::INFO
    @logger.debug('debug message')
    @logger.info('info message')
    @logger.warn('warn message')
    @logger.error('error message')
    @logger.fatal('fatal message')
    log = File.read(@file)
    assert_not_match(/debug message/, log)
    %w(INFO WARN ERROR FATAL).each { |level| assert_match(/#{level} -- : #{level.downcase} message/, log) }
    assert_true @logger.info?
    assert_false @logger.debug?
    assert_false @logger.trace?
  end

  def test_trace
    logger
    @logger.trace('hidden')
    @logger.level = RLogger::TRACE
    assert_true @logger.trace?
    @logger.trace('shown')
    log = File.read(@file)
    assert_not_match(/hidden/, log)
    assert_match(/TRACE -- : shown/, log)
  end

  def test_unknown
    logger
    @logger.unknown('unknown message')
    assert_match(/ANY -- : unknown message/, File.read(@file))
  end

  def test_shift_by_size
    logger(2, 200)
    5.times { @logger.info('x' * 100) }
    assert_equal %w(roma.log roma.log.0), files
  end

  def test_set_log_shift_size
    logger(2, 1_000_000)
    @logger.set_log_shift_size(200)
    5.times { @logger.info('x' * 100) }
    assert_equal %w(roma.log roma.log.0), files
  end

  # A file from before the last period is renamed after its end.
  def test_shift_daily
    logger('daily')
    @logger.info('old')
    make_old
    @logger.info('new')
    yesterday = (Time.now - 86_400).strftime('%Y%m%d')
    assert_equal ['roma.log', "roma.log.#{yesterday}2359"], files
    assert_not_match(/old/, File.read(@file))
  end

  def test_set_log_shift_age_to_a_period
    logger(2, 1_000_000)
    @logger.set_log_shift_age('min')
    @logger.info('old')
    make_old
    @logger.info('new')
    assert_equal ['roma.log', "roma.log.#{(Time.now - 60).strftime('%Y%m%d%H%M')}"], files
  end

  def test_shift_fails_if_the_file_exists
    logger('daily')
    @logger.info('old')
    make_old
    File.write("#{@file}.#{(Time.now - 86_400).strftime('%Y%m%d')}2359", '')
    # Logger reports the error and goes on writing to the same file.
    assert_nothing_raised { @logger.info('new') }
    assert_match(/new/, File.read(@file))
  end

  data('min' => ['min', Time.local(2026, 3, 4, 5, 5, 59)],
       'hour' => ['hour', Time.local(2026, 3, 4, 4, 59, 59)],
       'daily' => ['daily', Time.local(2026, 3, 3, 23, 59, 59)],
       'weekly' => ['weekly', Time.local(2026, 2, 28, 23, 59, 59)],
       'monthly' => ['monthly', Time.local(2026, 2, 28, 23, 59, 59)])
  def test_previous_period_end(data)
    age, expected = data
    logger('daily')
    @logger.set_log_shift_age(age)
    # Wednesday
    assert_equal expected, logdev.send(:previous_period_end, Time.local(2026, 3, 4, 5, 6, 7))
  end

  data('min' => 'min', 'hour' => 'hour')
  def test_create_with_a_period(age)
    logger(age)
    @logger.info('message')
    assert_equal ['roma.log'], files
  end

  def test_stderr_wrapper
    saved = RLogger.instance
    RLogger.class_variable_set(:@@singleton_instance, logger)
    Roma::Logging::StderrWrapper.new.write('to stderr')
    assert_match(/ERROR -- : STDERR:to stderr/, File.read(@file))
  ensure
    RLogger.class_variable_set(:@@singleton_instance, saved)
  end
end
