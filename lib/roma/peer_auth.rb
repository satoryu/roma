require 'openssl'
require 'securerandom'

module Roma
  # The authentication of a connection by the secret of the cluster,
  # config.cluster_secret. The node sends a nonce, and the peer replies the
  # HMAC of it by the secret, so that the secret isn't sent and a reply
  # can't be used again:
  #
  #   auth_nonce\r\n       -> <nonce>\r\n
  #   auth <digest>\r\n    -> AUTHENTICATED\r\n | CLIENT_ERROR ...\r\n
  #
  # A node without the secret authenticates any peer.
  module PeerAuth
    # Raised when the peer replies something else than the protocol, so the
    # connection can't be used.
    class Error < StandardError; end

    def self.nonce = SecureRandom.hex(16)

    def self.digest(secret, nonce) = OpenSSL::HMAC.hexdigest('SHA256', secret, nonce)

    def self.valid?(secret, nonce, digest)
      !digest.nil? && OpenSSL.secure_compare(digest(secret, nonce), digest)
    end

    # Authenticates the connection +con+, which has write and gets, by
    # +secret+. Returns false if the node rejects the secret, so that the
    # connection is still usable for the commands without it.
    def self.authenticate(con, secret)
      con.write("auth_nonce\r\n")
      nonce = con.gets
      raise Error, "no nonce: #{nonce.inspect}" unless nonce&.match?(/\A\h+\r\n\z/)

      con.write("auth #{digest(secret, nonce.chomp)}\r\n")
      case con.gets
      when "AUTHENTICATED\r\n" then true
      when /\ACLIENT_ERROR/ then false
      else raise Error, 'no reply to auth'
      end
    end
  end
end
