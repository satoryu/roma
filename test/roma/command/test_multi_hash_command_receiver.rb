require 'test_helper'
require 'receiver_command_test_helper'

class MultiHashCommandReceiverTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  def setup
    super
    # Hashes are made in Roma.config.storage.path, named after this node.
    @conn.stats.address = 'multihashcommandtest'
    @conn.stats.port = Process.pid.to_s
    @path = "#{Roma.config.storage.path}/#{@conn.stats.my_node_id}"
  end

  def teardown
    @conn.storages.each { |name, st| st.closedb unless name == 'roma' }
    FileUtils.rm_rf(@path)
    super
  end

  # Relayed by def_command_with_relay, which puts this node's reply first.
  def replies(reply, other: 'STORED')
    "#{{ @conn.stats.my_node_id => reply, OTHER_NID => other }}\r\n"
  end

  def test_defhash
    assert_equal replies('roma'), @conn.request('defhash')
    assert_equal replies('STORED'), @conn.request('defhash roma')
    assert_equal "CLIENT_ERROR none does not find.\r\n", @conn.request('defhash none')
    assert_equal ["rdefhash \r\n", "rdefhash roma\r\n"], @conn.broadcasts
  end

  def test_createhash_and_deletehash
    @conn.relay_reply = 'CREATED'
    assert_equal replies('CREATED', other: 'CREATED'), @conn.request('createhash hash1')
    assert_equal "roma hash1\r\n", @conn.request('hashlist')
    assert_equal "SERVER_ERROR hash1 already exists.\r\n", @conn.request('rcreatehash hash1')

    # The files of the hash are deleted too.
    FileUtils.mkdir_p("#{@path}/hash1")
    assert_equal "DELETED\r\n", @conn.request('rdeletehash hash1')
    assert_equal "roma\r\n", @conn.request('hashlist')
    assert_false File.exist?("#{@path}/hash1")
  end

  def test_mounthash_and_umounthash
    @conn.request('rcreatehash hash1')
    # HashStorage keeps no files; make the directory a hash would have.
    FileUtils.mkdir_p("#{@path}/hash1")
    assert_equal "UNMOUNTED\r\n", @conn.request('rumounthash hash1')
    assert_equal "roma\r\n", @conn.request('hashlist')
    # The files stay, so it can be mounted again.
    assert_equal "MOUNTED\r\n", @conn.request('rmounthash hash1')
    assert_equal "roma hash1\r\n", @conn.request('hashlist')
    assert_equal "SERVER_ERROR hash1 already mounted.\r\n", @conn.request('rmounthash hash1')
  end

  def test_errors
    assert_equal "SERVER_ERROR nohash does not find.\r\n", @conn.request('rmounthash nohash')
    assert_equal "SERVER_ERROR nohash does not find.\r\n", @conn.request('rumounthash nohash')
    assert_equal "SERVER_ERROR nohash does not exists.\r\n", @conn.request('rdeletehash nohash')
    assert_equal "SERVER_ERROR default hash can't unmount.\r\n", @conn.request('rumounthash roma')
    %w(createhash deletehash mounthash umounthash).each do |command|
      assert_equal "CLIENT_ERROR usage:#{command} <name>\r\n", @conn.request("r#{command}")
    end
  end
end
