require 'socket'
require 'roma/peer_auth'

# A node that authenticates the connections by +secret+, as
# Roma::Command::AuthCommandReceiver does, and answers whoami with
# AUTHENTICATED or UNAUTHENTICATED, by whether the connection is.
#
#   node = AuthNode.new('a secret of 16 bytes')
#   node.node_id # => "127.0.0.1_54321"
#   node.close
class AuthNode
  attr_reader :node_id

  def initialize(secret)
    @secret = secret
    @server = TCPServer.new('127.0.0.1', 0)
    @node_id = "127.0.0.1_#{@server.addr[1]}"
    @clients = []
    @thread = Thread.new do
      loop do
        client = @server.accept
        @clients << client
        Thread.new { serve(client) }
      end
    end
  end

  def close
    @thread.kill
    @clients.each(&:close)
    @server.close
  end

  private

  def serve(client)
    nonce = nil
    authenticated = false
    while (line = client.gets)
      cmd, arg = line.split
      case cmd
      when 'auth_nonce'
        nonce = Roma::PeerAuth.nonce
        client.write("#{nonce}\r\n")
      when 'auth'
        authenticated = !nonce.nil? && Roma::PeerAuth.valid?(@secret, nonce, arg)
        nonce = nil
        client.write(authenticated ? "AUTHENTICATED\r\n" : "CLIENT_ERROR authentication failed\r\n")
      when 'whoami'
        client.write(authenticated ? "AUTHENTICATED\r\n" : "UNAUTHENTICATED\r\n")
      end
    end
  rescue IOError
    nil
  end
end
