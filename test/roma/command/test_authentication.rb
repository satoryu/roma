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

  # The names of the commands of a node with the bundled plugins and debug.
  def command_names
    (Roma::CommandPlugin::BUNDLED + %w(debug)).each { |name| require "roma/command_plugin/#{name}" }
    receiver = Class.new(Roma::Command::Receiver)
    Roma::CommandPlugin.plugins.each { |plugin| receiver.include(plugin) }
    receiver.public_instance_methods.map(&:to_s).grep(/\Aev_/).map { |m| m.delete_prefix('ev_') }
  end

  # The commands that the nodes relay to the others, such as rbalse for
  # balse, are only for the nodes, and those relayed are admin commands.
  def test_relayed_commands_need_it
    names = command_names
    relayed = names.select { |name| name.start_with?('r') && names.include?(name[1..]) }
    assert_not_empty relayed
    assert_empty relayed - Roma::Command::Authentication.commands.to_a
    assert_empty relayed.map { |name| name[1..] } - %w(set delete) - Roma::Command::Authentication.commands.to_a
  end

  # The commands that change the settings, but set_expt, which changes the
  # expire time of a key.
  def test_setting_commands_need_it
    settings = command_names.grep(/\Aset_/) - %w(set_expt)
    assert_not_empty settings
    assert_empty settings - Roma::Command::Authentication.commands.to_a
  end

  def test_admin_commands_need_it
    admin = %w(balse shutdown shutdown_self restart release recover balance createhash deletehash
               switch_failover gather_logs show_logs eval)
    assert_empty admin - command_names
    assert_empty admin - Roma::Command::Authentication.commands.to_a
  end

  # The clients' commands, and those that read the cluster.
  def test_client_commands_dont_need_it
    open = %w(get set delete gets incr alist_push map_set mapcount_countup stat stats nodelist routingdump
              mklhash whoami version quit auth auth_nonce set_expt)
    assert_empty open - command_names
    assert_empty open & Roma::Command::Authentication.commands.to_a
  end
end
