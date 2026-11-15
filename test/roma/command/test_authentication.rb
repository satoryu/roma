require 'test_helper'
require 'roma/command/receiver'
require 'roma/command/authentication'

class AuthenticationTest < Test::Unit::TestCase
  # Commands of a plugin, one of which needs the authentication.
  module Commands
    extend Roma::Command::Authentication

    def ev_open(_s) = send_data("OPEN\r\n")
    def ev_rcommand(_s) = send_data("DONE\r\n")
    require_authentication :rcommand
  end

  class Connection
    include Commands

    attr_reader :sent

    def initialize(authenticated: false)
      @authenticated = authenticated
      @sent = +''
    end

    def send_data(data)
      @sent << data
    end
  end

  def teardown
    Roma.reset_config
  end

  def test_require_authentication
    Roma.config.cluster_secret = 'a secret of the cluster'
    con = Connection.new
    con.ev_rcommand([])
    con.ev_open([])
    assert_equal "CLIENT_ERROR authentication required\r\nOPEN\r\n", con.sent

    con = Connection.new(authenticated: true)
    con.ev_rcommand([])
    assert_equal "DONE\r\n", con.sent
    assert_include Roma::Command::Authentication.commands, 'rcommand'
  end

  def test_without_the_secret
    con = Connection.new
    con.ev_rcommand([])
    assert_equal "DONE\r\n", con.sent
  end

  # The commands that the nodes relay to the others, such as rbalse for
  # balse, are only for the nodes.
  def test_relayed_commands_need_it
    Roma::CommandPlugin::BUNDLED.each { |name| require "roma/command_plugin/#{name}" }
    receiver = Class.new(Roma::Command::Receiver)
    Roma::CommandPlugin.plugins.each { |plugin| receiver.include(plugin) }
    names = receiver.public_instance_methods.map(&:to_s).grep(/\Aev_/).map { |m| m.delete_prefix('ev_') }
    relayed = names.select { |name| name.start_with?('r') && names.include?(name[1..]) }
    assert_not_empty relayed
    assert_empty relayed - Roma::Command::Authentication.commands.to_a
  end
end
