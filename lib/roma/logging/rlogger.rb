# ROMA's logger.
#
# rlogger.rb - it is an extension to a standard logger for ROMA
#
require 'logger'

module Roma
  module Logging
    class RLogger
      VERSION = '0.0.1'

      module Severity
        TRACE = -1
        DEBUG = 0
        INFO = 1
        WARN = 2
        ERROR = 3
        FATAL = 4
        UNKNOWN = 5
      end
      include Severity

      module ExtLogDev
        def extendLogDev
          return unless @logdev

          @logdev.extend(ExtCheckShift)
          @logdev.extend(ExtShiftAge)
          @logdev.extend(WritableShiftAge)
          @logdev.extend(WritableShiftSize)
        end

        def shift_age=(age)
          return unless @logdev

          @logdev.shift_age = age
        end

        def shift_size=(size)
          return unless @logdev

          @logdev.shift_size = size
        end
      end

      module WritableShiftAge
        def shift_age=(age)
          return unless @shift_age

          @shift_age = age
        end
      end

      module WritableShiftSize
        def shift_size=(size)
          return unless @shift_size

          @shift_size = size
        end
      end

      module ExtCheckShift
        private

        def check_shift_log
          if @shift_age.is_a?(Integer)
            # NOTE: always returns false if '0'.
            lock_shift_log { shift_log_age } if @filename && (@shift_age > 0) && (@dev.stat.size > @shift_size)
          else
            now = Time.now
            period_end = previous_period_end(now)
            lock_shift_log { shift_log_period(period_end) } if @dev.stat.mtime.to_i <= period_end.to_i
          end
        end
      end

      module ExtShiftAge
        SECONDS_IN_DAY = 24 * 60 * 60

        private

        # +period_end+ is the end of the period the log is for.
        def shift_log_period(period_end)
          postfix = period_end.strftime('%Y%m%d%H%M')
          age_file = "#{@filename}.#{postfix}"
          raise "'#{age_file}' already exists." if FileTest.exist?(age_file)

          @dev.close
          File.rename(@filename, age_file)
          @dev = create_logfile(@filename)
          true
        end

        def previous_period_end(now)
          ret = nil
          case @shift_age
          when /^min$/
            t = now - (1 * 60)
            ret = Time.mktime(t.year, t.month, t.mday, t.hour, t.min, 59)
          when /^hour$/
            t = now - (1 * 60 * 60)
            ret = Time.mktime(t.year, t.month, t.mday, t.hour, 59, 59)
          when /^daily$/
            ret = end_of_day(now - (1 * SECONDS_IN_DAY))
          when /^weekly$/
            ret = end_of_day(now - ((now.wday + 1) * SECONDS_IN_DAY))
          when /^monthly$/
            ret = end_of_day(now - (now.mday * SECONDS_IN_DAY))
          else
            ret = now
          end
          ret
        end

        def end_of_day(t)
          Time.mktime(t.year, t.month, t.mday, 23, 59, 59)
        end
      end

      module ExtTrace
        private

        SEV_LABEL = %w(DEBUG INFO WARN ERROR FATAL ANY)

        def format_severity(severity)
          return 'TRACE' if @level <= RLogger::TRACE and severity <= RLogger::TRACE

          SEV_LABEL[severity] || 'ANY'
        end
      end

      @@singleton_instance = nil

      def self.create_singleton_instance(logdev, shift_age = 0, shift_size = 1_048_576)
        @@singleton_instance = RLogger.new(logdev, shift_age, shift_size)
        private_class_method :new, :allocate
      end

      def self.instance
        @@singleton_instance
      end

      def initialize(logdev, shift_age = 0, shift_size = 1_048_576)
        # Logger knows only daily, weekly and monthly periods; RLogger shifts
        # the log itself, so give Logger one of them and set the real one.
        logger_shift_age = %w(min hour).include?(shift_age) ? 'daily' : shift_age
        @wrap_logger = Logger.new(logdev, logger_shift_age, shift_size)
        @wrap_logger.extend(ExtTrace)
        @wrap_logger.extend(ExtLogDev)
        @wrap_logger.extendLogDev
        @wrap_logger.shift_age = shift_age if logger_shift_age != shift_age
      end

      def level=(severity)
        @wrap_logger.level = severity
      end

      def trace? = @wrap_logger.level <= TRACE

      def debug? = @wrap_logger.debug?

      def info? = @wrap_logger.info?

      def warn? = @wrap_logger.warn?

      def error? = @wrap_logger.error?

      def fatal? = @wrap_logger.fatal?

      def trace(progname = nil, &)
        @wrap_logger.add(TRACE, nil, progname, &)
      end

      def debug(progname = nil, &)
        @wrap_logger.debug(progname, &)
      end

      def info(progname = nil, &)
        @wrap_logger.info(progname, &)
      end

      def warn(progname = nil, &)
        @wrap_logger.warn(progname, &)
      end

      def error(progname = nil, &)
        @wrap_logger.error(progname, &)
      end

      def fatal(progname = nil, &)
        @wrap_logger.fatal(progname, &)
      end

      def unknown(progname = nil, &)
        @wrap_logger.unknown(progname, &)
      end

      def close = @wrap_logger.close

      def shift_size=(size)
        @wrap_logger.shift_size = size
      end

      def shift_age=(age)
        @wrap_logger.shift_age = age
      end
    end
  end
end
