# Before lib is loaded, so that loading it is measured too.
require_relative 'start_coverage' if ENV['COVERAGE']
require 'test/unit'
require 'English'
# The tests poll nodes that are down, so avoid the occasional 5-second
# failure of refused connections.
require 'roma/tcp_fast_fallback'

require 'roma_test_utils'
