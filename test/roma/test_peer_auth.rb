require 'test_helper'
require 'roma/peer_auth'

class PeerAuthTest < Test::Unit::TestCase
  SECRET = 'a secret of the cluster'.freeze

  # A connection that answers with +replies+, one line each gets, and keeps
  # what is written.
  class Connection
    attr_reader :written

    def initialize(*replies)
      @replies = replies
      @written = +''
    end

    def write(data)
      @written << data
    end

    def gets = @replies.shift
  end

  def test_valid
    nonce = Roma::PeerAuth.nonce
    digest = Roma::PeerAuth.digest(SECRET, nonce)
    assert_true Roma::PeerAuth.valid?(SECRET, nonce, digest)
    assert_false Roma::PeerAuth.valid?('another secret', nonce, digest)
    assert_false Roma::PeerAuth.valid?(SECRET, Roma::PeerAuth.nonce, digest)
    assert_false Roma::PeerAuth.valid?(SECRET, nonce, nil)
    assert_false Roma::PeerAuth.valid?(SECRET, nonce, 'short')
  end

  def test_nonces_differ
    assert_not_equal Roma::PeerAuth.nonce, Roma::PeerAuth.nonce
  end

  # The digest of the nonce is sent, not the secret.
  def test_authenticate
    con = Connection.new("abc123\r\n", "AUTHENTICATED\r\n")
    assert_true Roma::PeerAuth.authenticate(con, SECRET)
    assert_equal "auth_nonce\r\nauth #{Roma::PeerAuth.digest(SECRET, 'abc123')}\r\n", con.written
    assert_not_include con.written, SECRET
  end

  def test_authenticate_rejected
    con = Connection.new("abc123\r\n", "CLIENT_ERROR authentication failed\r\n")
    assert_false Roma::PeerAuth.authenticate(con, SECRET)
  end

  data('no nonce' => [nil],
       'unknown command' => ["\r\n", "ERROR: 'auth_nonce' is not roma command.\r\n"],
       'no reply to auth' => ["abc123\r\n", nil],
       'other reply to auth' => ["abc123\r\n", "ERROR\r\n"])
  def test_authenticate_broken(replies)
    assert_raise(Roma::PeerAuth::Error) { Roma::PeerAuth.authenticate(Connection.new(*replies), SECRET) }
  end
end
