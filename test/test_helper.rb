require 'test/unit'
require 'English'
# The tests poll nodes that are down, so avoid the occasional 5-second
# failure of refused connections.
require 'roma/tcp_fast_fallback'

require 'roma_test_utils'
