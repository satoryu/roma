require 'test/unit'
require 'socket'

# The tests poll nodes that are down, so avoid the occasional 5-second
# failure of refused connections (see lib/roma/romad.rb).
Socket.tcp_fast_fallback = false if Socket.respond_to?(:tcp_fast_fallback=)

require 'roma_test_utils'
