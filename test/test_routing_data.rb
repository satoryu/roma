require 'test_helper'

require 'roma/routing/routing_data'
require 'yaml'
require 'tmpdir'
require 'fileutils'

class RoutingDataTest < Test::Unit::TestCase
  self.test_order = :defined
  def setup
    @dir = Dir.mktmpdir('roma_routing_data')
    @fname = File.join(@dir, 'routing_data.test.route')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end



  def test_save_load
    rd=Roma::Routing::RoutingData.create(32,8,1,['roma0_3300'])
    rd.save(@fname)
    rd2=Roma::Routing::RoutingData.load(@fname)
    assert_equal(YAML.dump(rd), YAML.dump(rd2))
  end

  def test_next_vnode
    rd=Roma::Routing::RoutingData.create(32,8,1,['roma0_3300'])
    assert_equal(0x01000000, rd.next_vnode(0x00000000))
    assert_equal(0x00000000, rd.next_vnode(0xff000000))
    assert_equal(0x56000000, rd.next_vnode(0x55000000))
  end

  def test_saved_format
    rd=Roma::Routing::RoutingData.create(32,8,1,['roma0_3300'])
    decoded_rd=Roma::Routing::RoutingData.decode_binary(rd.dump_binary)
    decoded_rd.save(@fname)
    rd_text=File.open(@fname){|f| f.read }
    assert_not_match(/\!binary \|\-/, rd_text)
  end

  def test_create_nodes_from_v_idx
    rd=Roma::Routing::RoutingData.create(32,8,1,['roma0','roma1','roma2'])
    rd.nodes.clear
    rd.create_nodes_from_v_idx
    assert_equal(['roma0','roma1','roma2'], rd.nodes)
  end

  def test_create
    # digest bit count 32
    # vn bit count 8
    # redundancy 1
    # array of node ID [roma0_3300]
    rd=Roma::Routing::RoutingData.create(32,8,1,['roma0_3300'])

    assert_equal(256, rd.v_idx.length)
    assert_equal(1, rd.nodes.length)
    assert_equal(0xff000000, rd.search_mask)
    assert_equal(32, rd.dgst_bits)
    assert_equal(8, rd.div_bits)
    assert_equal(1, rd.rn)
    # digest bit count 32
    # vn bit count 9
    # redundancy 2
    # array of node ID ['roma0_3300','roma1_3300','roma2_3300']
    rd=Roma::Routing::RoutingData.create(32,9,2,['roma0_3300','roma1_3300','roma2_3300'])

    assert_equal(512, rd.v_idx.length)
    assert_equal(3, rd.nodes.length)
    assert_equal(4286578688, rd.search_mask)
    assert_equal(32, rd.dgst_bits)
    assert_equal(9, rd.div_bits)
    assert_equal(2, rd.rn)
    c0=c1=c2=0
    rd.v_idx.each_value{|v|
      case v[0]
      when 'roma0_3300'
        c0+=1
      when 'roma1_3300'
        c1+=1
      when 'roma2_3300'
        c2+=1
      end
    }
    # confirming dispersion is lower than 10%
    assert( (c0-c1).abs < rd.v_idx.length/10 )
    assert( (c1-c2).abs < rd.v_idx.length/10 )
  end

  def test_dump_binary
    rd=Roma::Routing::RoutingData.create(32,9,2,['roma0_3300','roma1_3300'])
    # set to a bummy clock
    (2**rd.div_bits).times{|i|
      vn=i<<(rd.dgst_bits-rd.div_bits)
      rd.v_clk[vn] = i
    }

    bin = rd.dump_binary
#    puts bin.length

    magic, ver, dgst_bits, div_bits, rn, nodeslen = bin.unpack('a2nCCCn')
    assert_equal('RT', magic)
    assert_equal(1, ver)
    assert_equal(rd.dgst_bits, dgst_bits)
    assert_equal(rd.div_bits, div_bits)
    assert_equal(rd.rn, rn)
    assert_equal(rd.nodes.length, nodeslen)
    bin = bin[9..-1]
    nodeslen.times{|i|
      len, = bin.unpack('n')
      bin = bin[2..-1]
      nid, = bin.unpack("a#{len}")
      bin = bin[len..-1]
      assert_equal(rd.nodes[i], nid)
    }
    (2**div_bits).times{|i|
      vn=i<<(dgst_bits-div_bits)
      v_clk,len = bin.unpack('Nc')
      assert_equal(rd.v_clk[vn], v_clk)
      assert_equal(rd.v_idx[vn].length, len)
#      puts "#{i} #{vn} #{v_clk} #{len}"
      bin = bin[5..-1]
      len.times{|i|
        idx, = bin.unpack('n')
        assert_equal(rd.nodes[idx], rd.v_idx[vn][i])
        bin = bin[2..-1]
#        puts rd.nodes[idx]
      }
    }
    assert_equal(0, bin.length)
  end

  def test_dump_binary2
    rd=Roma::Routing::RoutingData.create(32,9,2,['roma0_3300','roma1_3300'])
    # set to a bummy clock
    (2**rd.div_bits).times{|i|
      vn=i<<(rd.dgst_bits-rd.div_bits)
      rd.v_clk[vn] = i
    }

    bin = rd.dump_binary
    bin2 = Roma::Routing::RoutingData.decode_binary(bin).dump_binary

    assert_equal(bin, bin2)
  end

  # The routing table writes its changes to logs next to the file:
  # <file>.1, <file>.2 and so on. Lines starting with # are comments.
  def write_log(n, *lines)
    File.write("#{@fname}.#{n}", lines.map { |l| l.start_with?('#') ? "#{l}\n" : "2026-01-01T00:00:00.1 #{l}\n" }.join)
  end

  def test_load_with_logs
    rd = Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300'])
    rd.save(@fname)
    write_log(1, 'join roma1_3300', 'setroute 0 5 roma1_3300', '# a comment')
    write_log(2, 'leave roma0_3300')
    loaded = Roma::Routing::RoutingData.load(@fname)
    assert_equal ['roma1_3300'], loaded.nodes
    assert_equal ['roma1_3300'], loaded.v_idx[0]
    assert_equal 5, loaded.v_clk[0]
  end

  def test_load_with_a_broken_log
    Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300']).save(@fname)
    write_log(1, 'unknown roma1_3300')
    assert_raise_message(/parse error/) { Roma::Routing::RoutingData.load(@fname) }
  end

  # A snapshot puts the logs but the last into the file.
  def test_snapshot
    Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300']).save(@fname)
    write_log(1, 'join roma1_3300')
    write_log(2, 'join roma2_3300')
    assert_true Roma::Routing::RoutingData.snapshot(@fname)
    assert_equal ['roma0_3300', 'roma1_3300'], Roma::Routing::RoutingData.load_snapshot(@fname).nodes
    assert_true File.exist?("#{@fname}~")
    assert_true File.exist?("#{@fname}.1~")
    assert_true File.exist?("#{@fname}.2")
  end

  def test_snapshot_without_enough_logs
    Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300']).save(@fname)
    write_log(1, 'join roma1_3300')
    assert_false Roma::Routing::RoutingData.snapshot(@fname)
  end

  def test_get_lost_vnodes
    rd = Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300'])
    assert_equal [], rd.get_lost_vnodes
    rd.v_idx[0] = []
    assert_equal [0], rd.get_lost_vnodes
  end

  # With replication in a host, both copies may be on one host.
  def test_create_with_replication_in_host
    rd = Roma::Routing::RoutingData.create(32, 3, 2, %w(roma0_3300 roma0_3301), true)
    rd.v_idx.each_value { |nids| assert_equal %w(roma0_3300 roma0_3301), nids.sort }
  end
end
