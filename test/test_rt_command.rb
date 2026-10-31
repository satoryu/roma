require 'test_helper'
require 'command_test_harness'

# Unit tests for the routing commands (Roma::Command::RoutingCommandReceiver).
# The harness has a routing table of two nodes and 8 vnodes. Each vnode is on
# one node, chosen at random, because both nodes are on the same host.
class RoutingCommandTest < Test::Unit::TestCase
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID
  # The first vnode.
  VN = 0

  def setup
    @conn = CommandTestHarness.new
    @rttable = @conn.rttable
    # The node VN is on.
    @vn_nid = @rttable.search_nodes(VN).first
  end

  def teardown
    @conn.close
  end

  def replies(reply, other: reply)
    "#{{ OTHER_NID => other, NID => reply }}\r\n"
  end

  # Reads the replies to routingdump with a length line: the length, the
  # dump and END.
  def parse_sized_dump(reply)
    size, rest = reply.split("\r\n", 2)
    assert_equal "\r\nEND\r\n", rest[size.to_i..]
    rest[0, size.to_i]
  end

  def test_join
    assert_equal "ADDED\r\n", @conn.request('join localhost_11213')
    assert_equal [NID, OTHER_NID, 'localhost_11213'], @rttable.nodes
    assert_match(/ join localhost_11213\z/, @rttable.event.last)

    # Joining again changes nothing.
    assert_equal "ADDED\r\n", @conn.request('join localhost_11213')
    assert_equal [NID, OTHER_NID, 'localhost_11213'], @rttable.nodes
    assert_equal 1, @rttable.event.size
  end

  def test_leave
    @rttable.enabled_failover = true
    assert_equal "DELETED\r\n", @conn.request("leave #{OTHER_NID}")
    assert_equal [NID], @rttable.nodes
    assert_match(/ leave #{OTHER_NID}\z/, @rttable.event.last)
  end

  def test_leave_while_failover_is_disabled
    # It replies DELETED, but the node stays.
    assert_equal "DELETED\r\n", @conn.request("leave #{OTHER_NID}")
    assert_equal [NID, OTHER_NID], @rttable.nodes
  end

  def test_nodelist
    assert_equal "#{NID} #{OTHER_NID}\r\n", @conn.request('nodelist')
  end

  def test_create_nodes_from_v_idx
    @conn.request('join localhost_11213')
    assert_equal "CREATED\r\n", @conn.request('create_nodes_from_v_idx')
    # localhost_11213 has no vnodes.
    assert_equal "#{NID} #{OTHER_NID}\r\n", @conn.request('nodelist')
  end

  def test_routingdump
    rd = Marshal.load(parse_sized_dump(@conn.request('routingdump')))
    assert_equal @rttable.v_idx, rd.v_idx
    assert_equal [NID, OTHER_NID], rd.nodes
  end

  def test_routingdump_yaml
    dump = @conn.request('routingdump yaml')
    assert_true dump.end_with?("\r\nEND\r\n")
    rd = YAML.unsafe_load(dump.delete_suffix("\r\nEND\r\n"))
    assert_equal @rttable.v_idx, rd.v_idx
  end

  def test_routingdump_yamlbytes
    yaml = @conn.request('routingdump yaml').delete_suffix("\r\nEND\r\n")
    # The size of what routingdump yaml sends, without the last "\r\n".
    assert_equal "#{yaml.length + 7}\r\nEND\r\n", @conn.request('routingdump yamlbytes')
  end

  def test_routingdump_json
    dump = @conn.request('routingdump json')
    assert_true dump.end_with?("\r\nEND\r\n")
    params, nodes, v_idx = JSON.parse(dump.delete_suffix("\r\nEND\r\n"))
    assert_equal({ 'dgst_bits' => 32, 'div_bits' => 3, 'rn' => 2 }, params)
    assert_equal [NID, OTHER_NID], nodes
    assert_equal [@vn_nid], v_idx[VN.to_s]
  end

  def test_routingdump_bin
    dump = parse_sized_dump(@conn.request('routingdump bin'))
    assert_equal @rttable.dump_binary, dump
  end

  def test_routingdump_unknown_format
    assert_equal "CLIENT_ERROR\r\n", @conn.request('routingdump xml')
  end

  def test_routingdump_with_sub_nid
    # The client connects from 127.0.0.1, so it sees the node names replaced.
    @rttable.sub_nid['127.0.0.0/24'] = { regexp: 'localhost', replace: 'vm' }
    rd = Marshal.load(parse_sized_dump(@conn.request('routingdump')))
    assert_equal ['vm_11211', 'vm_11212'], rd.nodes
    assert_equal [@vn_nid.sub('localhost', 'vm')], rd.v_idx[VN]
    # The routing table itself doesn't change.
    assert_equal [NID, OTHER_NID], @rttable.nodes

    @rttable.sub_nid.clear
    @rttable.sub_nid['10.0.0.0/8'] = { regexp: 'localhost', replace: 'vm' }
    rd = Marshal.load(parse_sized_dump(@conn.request('routingdump')))
    assert_equal [NID, OTHER_NID], rd.nodes
  end

  def test_enabled_repetition_in_routing
    assert_equal "false\r\n", @conn.request('enabled_repetition_in_routing?')

    # Both copies of a vnode on the same host.
    @conn.request("setroute #{VN} 0 #{NID} #{OTHER_NID}")
    assert_equal "true\r\n", @conn.request('enabled_repetition_in_routing?')

    assert_equal "CLIENT_ERROR\r\n", @conn.request('enabled_repetition_in_routing? yes')
  end

  def test_setroute_and_getroute
    assert_equal "-1 #{@vn_nid}\r\n", @conn.request("getroute #{VN}")

    assert_equal "STORED\r\n", @conn.request("setroute #{VN} 0 #{OTHER_NID} #{NID}")
    assert_equal [OTHER_NID, NID], @rttable.search_nodes(VN)
    # getroute replies the clock to give setroute next time.
    assert_equal "0 #{OTHER_NID} #{NID}\r\n", @conn.request("getroute #{VN}")

    # A clock older than the table's is refused.
    assert_equal "SERVER_ERROR It's old table.\r\n", @conn.request("setroute #{VN} 0 #{NID}")
    assert_equal [OTHER_NID, NID], @rttable.search_nodes(VN)
  end

  def test_setroute_adds_unknown_nodes
    assert_equal "STORED\r\n", @conn.request("setroute #{VN} 0 localhost_11213")
    assert_equal [NID, OTHER_NID, 'localhost_11213'], @rttable.nodes
  end

  def test_setroute_errors
    assert_equal "CLIENT_ERROR\r\n", @conn.request("setroute #{VN} 0")
    assert_equal "CLIENT_ERROR : irregular node name was input.[\"ｎｏｄｅ\"]\r\n",
                 @conn.request("setroute #{VN} 0 #{NID} ｎｏｄｅ")
    assert_equal "SERVER_ERROR 1 is not found.\r\n", @conn.request("setroute 1 0 #{NID}")
    assert_equal [@vn_nid], @rttable.search_nodes(VN)
  end

  def test_getroute_errors
    assert_equal "CLIENT_ERROR\r\n", @conn.request('getroute')
    assert_equal "END\r\n", @conn.request('getroute 1')
  end

  def test_mklhash
    root = @conn.request('mklhash 0')
    assert_equal "#{@rttable.mtree.get('0')}\r\n", root
    assert_match(/\A\h{40}\r\n\z/, root)

    @conn.request("setroute #{VN} 0 #{NID} #{OTHER_NID}")
    assert_not_equal root, @conn.request('mklhash 0')
  end

  def test_history_of_lost
    assert_equal "END\r\n", @conn.request('history_of_lost')

    # Every vnode of OTHER_NID is lost when it leaves.
    @rttable.enabled_failover = true
    @conn.request("leave #{OTHER_NID}")
    lost = @rttable.v_idx.select { |_vn, nids| nids.empty? }.keys
    assert_equal 4, lost.size
    assert_equal lost.map { |vn| "#{vn}\r\n" }.join + "END\r\n", @conn.request('history_of_lost')
    assert_equal lost.map { |vn| "#{vn}\r\n" }.join + "END\r\n", @conn.request('history_of_lost 20000101000000')

    future = (Time.now + 3600).strftime('%Y%m%d%H%M%S')
    assert_equal "END\r\n", @conn.request("history_of_lost #{future}")
  end

  def test_history_of_lost_with_invalid_time
    assert_equal "CLIENT_ERROR\r\n", @conn.request('history_of_lost 2000')
  end

  def test_set_auto_recover
    assert_equal replies('STORED'), @conn.request('set_auto_recover true 180')
    assert_equal ["rset_auto_recover true 180\r\n"], @conn.broadcasts
    assert_true @rttable.auto_recover
    assert_equal 180, @rttable.auto_recover_time

    @rttable.auto_recover_status = 'executing'
    assert_equal replies('STORED'), @conn.request('set_auto_recover false')
    assert_false @rttable.auto_recover
    assert_equal 'waiting', @rttable.auto_recover_status
    # The time stays when it is left out.
    assert_equal 180, @rttable.auto_recover_time
  end

  def test_rset_auto_recover
    assert_equal "STORED\r\n", @conn.request('rset_auto_recover true 180')
    assert_true @rttable.auto_recover
    assert_equal 180, @rttable.auto_recover_time
    assert_equal [], @conn.broadcasts
  end

  data('set' => 'set_auto_recover', 'rset' => 'rset_auto_recover')
  def test_auto_recover_errors(command)
    assert_equal "CLIENT_ERROR length must be greater than zero\r\n", @conn.request("#{command} true 0")
    assert_equal "CLIENT_ERROR number of arguments(0 for 1)\r\n", @conn.request("#{command} true 180 1")
    assert_equal [], @conn.broadcasts
    assert_false @rttable.auto_recover
    assert_equal 1800, @rttable.auto_recover_time
  end

  def test_set_auto_recover_invalid_value
    assert_equal "CLIENT_ERROR arguments must be true or false\r\n", @conn.request('set_auto_recover yes')
    assert_equal "CLIENT_ERROR arguments must be true or false\r\n", @conn.request('set_auto_recover')
    assert_equal [], @conn.broadcasts
    assert_false @rttable.auto_recover
  end

  def test_rset_auto_recover_invalid_value
    assert_equal "CLIENT_ERROR arguments must be true or false\r\n", @conn.request('rset_auto_recover yes')
    assert_false @rttable.auto_recover
  end

  def test_set_lost_action
    @rttable.lost_action = :auto_assign
    assert_equal replies('STORED'), @conn.request('set_lost_action shutdown')
    assert_equal ["rset_lost_action shutdown\r\n"], @conn.broadcasts
    assert_equal :shutdown, @rttable.lost_action
  end

  def test_rset_lost_action
    @rttable.lost_action = :shutdown
    assert_equal "STORED\r\n", @conn.request('rset_lost_action auto_assign')
    assert_equal :auto_assign, @rttable.lost_action
  end

  data('set' => 'set_lost_action', 'rset' => 'rset_lost_action')
  def test_lost_action_errors(command)
    @rttable.lost_action = :auto_assign
    assert_equal "CLIENT_ERROR changing lost_action must be auto_assign or shutdown\r\n",
                 @conn.request("#{command} no_action")
    assert_equal "CLIENT_ERROR changing lost_action must be auto_assign or shutdown\r\n",
                 @conn.request(command)

    # Can't change it from no_action, the default.
    @rttable.lost_action = :no_action
    assert_equal "CLIENT_ERROR can use this command only current lost action is auto_assign or shutdwn mode\r\n",
                 @conn.request("#{command} shutdown")
    assert_equal :no_action, @rttable.lost_action
    assert_equal [], @conn.broadcasts
  end

  def test_set_threshold_for_failover
    assert_equal replies('STORED'), @conn.request('set_threshold_for_failover 3')
    assert_equal ["rset_threshold_for_failover 3\r\n"], @conn.broadcasts
    assert_equal 3, @rttable.fail_cnt_threshold

    assert_equal "usage:set_threshold_for_failover <n>\r\n", @conn.request('set_threshold_for_failover 0')
    assert_equal "usage:set_threshold_for_failover <n>\r\n", @conn.request('set_threshold_for_failover')
    assert_equal 3, @rttable.fail_cnt_threshold
  end

  def test_rset_threshold_for_failover
    assert_equal "STORED\r\n", @conn.request('rset_threshold_for_failover 3')
    assert_equal 3, @rttable.fail_cnt_threshold

    assert_equal "usage:rset_threshold_for_failover <n>\r\n", @conn.request('rset_threshold_for_failover x')
    assert_equal 3, @rttable.fail_cnt_threshold
  end

  def test_set_gap_for_failover
    assert_equal replies('STORED'), @conn.request('set_gap_for_failover 0.5')
    assert_equal ["rset_gap_for_failover 0.5\r\n"], @conn.broadcasts
    assert_equal 0.5, @rttable.fail_cnt_gap

    assert_equal "usage:set_gap_for_failover <n>\r\n", @conn.request('set_gap_for_failover')
    assert_equal 0.5, @rttable.fail_cnt_gap
  end

  def test_rset_gap_for_failover
    assert_equal "STORED\r\n", @conn.request('rset_gap_for_failover 0.5')
    assert_equal 0.5, @rttable.fail_cnt_gap
    assert_equal "usage:rset_gap_for_failover <n>\r\n", @conn.request('rset_gap_for_failover')
  end

  def test_add_rttable_sub_nid
    @conn.relay_reply = 'ADDED'
    assert_equal replies('ADDED'), @conn.request('add_rttable_sub_nid 127.0.0.0/24 localhost vm')
    assert_equal ["radd_rttable_sub_nid 127.0.0.0/24 localhost vm\r\n"], @conn.broadcasts
    assert_equal({ '127.0.0.0/24' => { regexp: 'localhost', replace: 'vm' } }, @rttable.sub_nid)

    assert_equal "usage:add_rttable_sub_nid <netmask> <regexp> <replace>\r\n",
                 @conn.request('add_rttable_sub_nid 10.0.0.0/8 localhost')
    assert_equal 1, @conn.broadcasts.size
  end

  def test_radd_rttable_sub_nid
    assert_equal "ADDED\r\n", @conn.request('radd_rttable_sub_nid 127.0.0.0/24 localhost vm')
    assert_equal({ '127.0.0.0/24' => { regexp: 'localhost', replace: 'vm' } }, @rttable.sub_nid)
    assert_equal "usage:add_rttable_sub_nid <netmask> <regexp> <replace>\r\n",
                 @conn.request('radd_rttable_sub_nid 10.0.0.0/8')
  end

  def test_delete_rttable_sub_nid
    @rttable.sub_nid['127.0.0.0/24'] = { regexp: 'localhost', replace: 'vm' }
    @conn.relay_reply = 'DELETED'
    assert_equal replies('DELETED'), @conn.request('delete_rttable_sub_nid 127.0.0.0/24')
    assert_equal ["rdelete_rttable_sub_nid 127.0.0.0/24\r\n"], @conn.broadcasts
    assert_equal({}, @rttable.sub_nid)

    @conn.relay_reply = 'NOT_FOUND'
    assert_equal replies('NOT_FOUND'), @conn.request('delete_rttable_sub_nid 127.0.0.0/24')
    assert_equal "usage:delete_rttable_sub_nid <netmask>\r\n", @conn.request('delete_rttable_sub_nid')
  end

  def test_rdelete_rttable_sub_nid
    @rttable.sub_nid['127.0.0.0/24'] = { regexp: 'localhost', replace: 'vm' }
    assert_equal "DELETED\r\n", @conn.request('rdelete_rttable_sub_nid 127.0.0.0/24')
    assert_equal "NOT_FOUND\r\n", @conn.request('rdelete_rttable_sub_nid 127.0.0.0/24')
    assert_equal "usage:delete_rttable_sub_nid <netmask>\r\n", @conn.request('rdelete_rttable_sub_nid')
  end

  def test_clear_rttable_sub_nid
    @rttable.sub_nid['127.0.0.0/24'] = { regexp: 'localhost', replace: 'vm' }
    @conn.relay_reply = 'CLEARED'
    assert_equal replies('CLEARED'), @conn.request('clear_rttable_sub_nid')
    assert_equal ["rclear_rttable_sub_nid\r\n"], @conn.broadcasts
    assert_equal({}, @rttable.sub_nid)
  end

  def test_rclear_rttable_sub_nid
    @rttable.sub_nid['127.0.0.0/24'] = { regexp: 'localhost', replace: 'vm' }
    assert_equal "CLEARED\r\n", @conn.request('rclear_rttable_sub_nid')
    assert_equal({}, @rttable.sub_nid)
  end

  def test_get_key_info
    d = Digest::SHA1.hexdigest('key1').hex % @rttable.hbits
    vn = @rttable.get_vnode_id(d)
    expected = "d = #{d} 0x#{d.to_s(16)}\r\n" \
               "vn = #{vn} 0x#{vn.to_s(16)}\r\n" \
               "nodes = #{@rttable.search_nodes(vn).inspect}\r\n" \
               "END\r\n"
    assert_equal expected, @conn.request('get_key_info key1')

    assert_equal "CLIENT_ERROR number of arguments(0 for 1)\r\n", @conn.request('get_key_info')
  end
end
