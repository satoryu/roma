require 'test_helper'

require 'roma/routing/routing_data'
require 'yaml'
require 'tmpdir'
require 'fileutils'

class RoutingDataTest < Test::Unit::TestCase
  self.test_order = :defined
  def setup
    @dir = Dir.mktmpdir('roma_routing_data')
    @fname = File.join(@dir, 'routing_data.test.route.yml')
    @log_prefix = File.join(@dir, 'routing_data.test.route')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_save_load
    routing_data = Roma::Routing::RoutingData.create(32, 8, 1, ['roma0_3300'])
    routing_data.save(@fname)
    rd2 = Roma::Routing::RoutingData.load(@fname)
    assert_equal(routing_data.dump_yaml, rd2.dump_yaml)
  end

  def test_next_vnode
    routing_data = Roma::Routing::RoutingData.create(32, 8, 1, ['roma0_3300'])
    assert_equal(0x01000000, routing_data.next_vnode(0x00000000))
    assert_equal(0x00000000, routing_data.next_vnode(0xff000000))
    assert_equal(0x56000000, routing_data.next_vnode(0x55000000))
  end

  def test_saved_format
    routing_data = Roma::Routing::RoutingData.create(32, 8, 1, ['roma0_3300'])
    decoded_routing_data = Roma::Routing::RoutingData.decode_binary(routing_data.dump_binary)
    decoded_routing_data.save(@fname)
    routing_text = File.read(@fname)
    assert_not_match(/!binary \|-/, routing_text)
  end

  # The routing file is a plain YAML of a Hash, without the tag of the class.
  def test_file_is_plain_yaml
    Roma::Routing::RoutingData.create(32, 1, 1, ['roma0_3300']).save(@fname)
    expected = { 'digest_bits' => 32, 'divide_bits' => 1, 'redundancy' => 1, 'nodes' => ['roma0_3300'],
                 'routes' => { 0 => ['roma0_3300'], 0x80000000 => ['roma0_3300'] },
                 'clocks' => { 0 => 0, 0x80000000 => 0 } }
    assert_equal expected, YAML.safe_load_file(@fname)
    assert_not_match(/!ruby/, File.read(@fname))
  end

  # A file with the tag of a Ruby class, as ROMA 1.x wrote, makes no object.
  def test_load_yaml_rejects_ruby_objects
    yaml = YAML.dump(Roma::Routing::RoutingData.create(32, 1, 1, ['roma0_3300']))
    assert_raise(Psych::DisallowedClass) { Roma::Routing::RoutingData.load_yaml(yaml) }
  end

  def test_load_yaml_without_a_key
    assert_raise_message(/key not found: "clocks"/) do
      Roma::Routing::RoutingData.load_yaml(YAML.dump('digest_bits' => 32, 'divide_bits' => 1, 'redundancy' => 1,
                                                     'nodes' => [], 'routes' => {}))
    end
  end

  def test_create_nodes_from_v_idx
    routing_data = Roma::Routing::RoutingData.create(32, 8, 1, %w(roma0 roma1 roma2))
    routing_data.nodes.clear
    routing_data.create_nodes_from_routes
    assert_equal(%w(roma0 roma1 roma2), routing_data.nodes)
  end

  def test_create
    # digest bit count 32
    # vnode bit count 8
    # redundancy 1
    # array of node ID [roma0_3300]
    routing_data = Roma::Routing::RoutingData.create(32, 8, 1, ['roma0_3300'])

    assert_equal(256, routing_data.routes.length)
    assert_equal(1, routing_data.nodes.length)
    assert_equal(0xff000000, routing_data.search_mask)
    assert_equal(32, routing_data.digest_bits)
    assert_equal(8, routing_data.divide_bits)
    assert_equal(1, routing_data.redundancy)
    # digest bit count 32
    # vnode bit count 9
    # redundancy 2
    # array of node ID ['roma0_3300','roma1_3300','roma2_3300']
    routing_data = Roma::Routing::RoutingData.create(32, 9, 2, %w(roma0_3300 roma1_3300 roma2_3300))

    assert_equal(512, routing_data.routes.length)
    assert_equal(3, routing_data.nodes.length)
    assert_equal(4_286_578_688, routing_data.search_mask)
    assert_equal(32, routing_data.digest_bits)
    assert_equal(9, routing_data.divide_bits)
    assert_equal(2, routing_data.redundancy)
    c0 = c1 = c2 = 0
    routing_data.routes.each_value do |v|
      case v[0]
      when 'roma0_3300'
        c0 += 1
      when 'roma1_3300'
        c1 += 1
      when 'roma2_3300'
        c2 += 1
      end
    end
    # confirming dispersion is lower than 10%
    assert((c0 - c1).abs < routing_data.routes.length / 10)
    assert((c1 - c2).abs < routing_data.routes.length / 10)
  end

  def test_dump_binary
    routing_data = Roma::Routing::RoutingData.create(32, 9, 2, %w(roma0_3300 roma1_3300))
    # set to a bummy clock
    (2**routing_data.divide_bits).times do |i|
      vnode = i << (routing_data.digest_bits - routing_data.divide_bits)
      routing_data.clocks[vnode] = i
    end

    bin = routing_data.dump_binary
    #    puts bin.length

    magic, ver, digest_bits, divide_bits, redundancy, nodeslen = bin.unpack('a2nCCCn')
    assert_equal('RT', magic)
    assert_equal(1, ver)
    assert_equal(routing_data.digest_bits, digest_bits)
    assert_equal(routing_data.divide_bits, divide_bits)
    assert_equal(routing_data.redundancy, redundancy)
    assert_equal(routing_data.nodes.length, nodeslen)
    bin = bin[9..-1]
    nodeslen.times do |i|
      len, = bin.unpack('n')
      bin = bin[2..-1]
      node_id, = bin.unpack("a#{len}")
      bin = bin[len..-1]
      assert_equal(routing_data.nodes[i], node_id)
    end
    (2**divide_bits).times do |i|
      vnode = i << (digest_bits - divide_bits)
      clocks, len = bin.unpack('Nc')
      assert_equal(routing_data.clocks[vnode], clocks)
      assert_equal(routing_data.routes[vnode].length, len)
      #      puts "#{i} #{vnode} #{clocks} #{len}"
      bin = bin[5..-1]
      len.times do |i|
        idx, = bin.unpack('n')
        assert_equal(routing_data.nodes[idx], routing_data.routes[vnode][i])
        bin = bin[2..-1]
        #        puts routing_data.nodes[idx]
      end
    end
    assert_equal(0, bin.length)
  end

  def test_dump_binary2
    routing_data = Roma::Routing::RoutingData.create(32, 9, 2, %w(roma0_3300 roma1_3300))
    # set to a bummy clock
    (2**routing_data.divide_bits).times do |i|
      vnode = i << (routing_data.digest_bits - routing_data.divide_bits)
      routing_data.clocks[vnode] = i
    end

    bin = routing_data.dump_binary
    bin2 = Roma::Routing::RoutingData.decode_binary(bin).dump_binary

    assert_equal(bin, bin2)
  end

  # The routing table writes its changes to logs next to the file:
  # <file>.1, <file>.2 and so on. Lines starting with # are comments.
  def write_log(n, *lines)
    File.write("#{@log_prefix}.#{n}", lines.map do |l|
      l.start_with?('#') ? "#{l}\n" : "2026-01-01T00:00:00.1 #{l}\n"
    end.join)
  end

  def test_load_with_logs
    routing_data = Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300'])
    routing_data.save(@fname)
    write_log(1, 'join roma1_3300', 'setroute 0 5 roma1_3300', '# a comment')
    write_log(2, 'leave roma0_3300')
    loaded = Roma::Routing::RoutingData.load(@fname)
    assert_equal ['roma1_3300'], loaded.nodes
    assert_equal ['roma1_3300'], loaded.routes[0]
    assert_equal 5, loaded.clocks[0]
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
    assert_equal %w(roma0_3300 roma1_3300), Roma::Routing::RoutingData.load_snapshot(@fname).nodes
    assert_true File.exist?("#{@fname}~")
    assert_true File.exist?("#{@log_prefix}.1~")
    assert_true File.exist?("#{@log_prefix}.2")
  end

  # The routing file is YAML, and its logs are not.
  def test_file_name_and_log_prefix
    assert_equal 'roma0_3300.route.yml', Roma::Routing::RoutingData.file_name('roma0_3300')
    assert_equal '/var/roma/roma0_3300.route', Roma::Routing::RoutingData.log_prefix('/var/roma/roma0_3300.route.yml')
  end

  # A backup of a log, such as roma0_3300.route.1~, is not a log.
  def test_log_files
    write_log(2, 'join roma1_3300')
    write_log(10, 'join roma2_3300')
    File.write("#{@log_prefix}.1~", '')
    File.write("#{@fname}~", '')
    assert_equal [[2, "#{@log_prefix}.2"], [10, "#{@log_prefix}.10"]],
                 Roma::Routing::RoutingData.new(32, 3, 1).log_files(@fname)
  end

  def test_snapshot_without_enough_logs
    Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300']).save(@fname)
    write_log(1, 'join roma1_3300')
    assert_false Roma::Routing::RoutingData.snapshot(@fname)
  end

  def test_lost_vnodes
    routing_data = Roma::Routing::RoutingData.create(32, 3, 1, ['roma0_3300'])
    assert_equal [], routing_data.lost_vnodes
    routing_data.routes[0] = []
    assert_equal [0], routing_data.lost_vnodes
  end

  # With replication in a host, both copies may be on one host.
  def test_create_with_replication_in_host
    routing_data = Roma::Routing::RoutingData.create(32, 3, 2, %w(roma0_3300 roma0_3301), true)
    routing_data.routes.each_value { |node_ids| assert_equal %w(roma0_3300 roma0_3301), node_ids.sort }
  end
end
