require 'socket'

# Since Ruby 3.4, TCPSocket.new tries IPv6 and IPv4 in parallel (Happy
# Eyeballs). When both are refused, e.g. for a node that is down, it
# sometimes takes 5 seconds to fail. Connect one address at a time instead.
Socket.tcp_fast_fallback = false if Socket.respond_to?(:tcp_fast_fallback=)
