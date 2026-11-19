require 'roma/configuration'
require 'roma/peer_auth'
require 'roma/command/authentication'

module Roma
  module Command
    # The authentication of a connection by config.cluster_secret, which the
    # commands of Authentication.commands need. See PeerAuth.
    module AuthCommandReceiver
      # auth_nonce
      def ev_auth_nonce(_s)
        @auth_nonce = PeerAuth.nonce
        send_data("#{@auth_nonce}\r\n")
      end

      # auth <digest>
      def ev_auth(s)
        # A nonce is for one try.
        nonce = @auth_nonce
        @auth_nonce = nil
        secret = Roma.config.cluster_secret
        if secret.nil? || (nonce && PeerAuth.valid?(secret, nonce, s[1]))
          @authenticated = true
          send_data("AUTHENTICATED\r\n")
        else
          @logger.warn("#{@addr}:#{@port} failed in the authentication")
          send_data("CLIENT_ERROR authentication failed\r\n")
        end
      end
    end
  end
end
