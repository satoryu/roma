require 'socket'
require 'timeout'
require 'json'
require 'time'
require 'digest/sha1'
require 'roma/routing/routing_data'

# A minimal client for server-side tests.
# It speaks ROMA's text protocol directly so that the tests don't depend on
# roma-client gem. The method names and return values follow roma-client's.
class RomaTestClient
  TIMEOUT_SEC = 5
  RETRY_COUNT = 3

  class RoutingTable
    attr_reader :rd, :hbits, :search_mask
    # Send requests to a secondary node to make the server forward them.
    attr_accessor :force_forward

    def initialize(rd)
      @rd = rd
      @hbits = 2**rd.dgst_bits
      @search_mask = rd.search_mask
      @force_forward = false
    end

    def nodes
      @rd.nodes.clone
    end

    def get_vnode_id(d)
      d & @search_mask
    end

    def search_nodes(vn)
      @rd.v_idx[vn].clone
    end

    def search_node(key)
      d = Digest::SHA1.hexdigest(key).hex % @hbits
      nodes = @rd.v_idx[get_vnode_id(d)]
      [@force_forward ? nodes[1] : nodes[0], d]
    end
  end

  @connections = {}

  class << self
    attr_reader :connections

    def close_all
      @connections.each_value { |con| con.close rescue nil }
      @connections.clear
    end
  end

  attr_accessor :rttable, :default_hash_name

  def initialize(nodes)
    @default_hash_name = 'roma'
    update_rttable(nodes)
  end

  def update_rttable(nodes = @rttable.nodes)
    nodes.each do |node|
      rd = fetch_routing_data(node)
      if rd
        @rttable = RoutingTable.new(rd)
        return
      end
    end
    raise 'failed to get a routing table'
  end

  def stats(filter: '', node: @rttable.nodes.first)
    lines = send_command(node, "stats #{filter}", nil, :multiplelines_receiver)
    lines.each_with_object({}) do |line, h|
      k, v = line.split(' ', 2)
      h[k] = v
    end
  end

  # storage commands

  def set(key, val, expt = 0, raw = false)
    store('set', key, val, expt, raw)
  end

  def add(key, val, expt = 0, raw = false)
    store('add', key, val, expt, raw)
  end

  def replace(key, val, expt = 0, raw = false)
    store('replace', key, val, expt, raw)
  end

  def append(key, val, expt = 0)
    store('append', key, val, expt, true)
  end

  def prepend(key, val, expt = 0)
    store('prepend', key, val, expt, true)
  end

  def cas(key, expt = 0, raw = false)
    raise 'A block is required' unless block_given?

    ret = request(key, "gets #{k(key)}", nil, :value_casid_receiver)
    return 'NOT_FOUND' if ret.empty?
    val, casid = ret
    val = Marshal.load(val) unless raw
    updated = yield val
    val = raw ? updated : Marshal.dump(updated)
    request(key, "cas #{k(key)} 0 #{expt.to_i} #{val.bytesize} #{casid}", val)
  end

  def delete(key)
    request(key, "delete #{k(key)}")
  end

  def out(key)
    request(key, "out #{k(key)}")
  end

  def get(key, raw = false)
    val = request(key, "get #{k(key)}", nil, :value_list_receiver)[0]
    return nil if val.nil?
    raw ? val : Marshal.load(val)
  end

  def gets(keys, raw = false)
    res = {}
    keys.group_by { |key| @rttable.search_node(key)[0] }.each do |nid, ks|
      cmd = "gets #{ks.map { |key| k(key) }.join(' ')}"
      res.merge!(send_command(nid, cmd, nil, :value_hash_receiver))
    end
    res.transform_values! { |v| Marshal.load(v) } unless raw
    res
  end

  def incr(key, val = 1)
    to_i_if_digits(request(key, "incr #{k(key)} #{val.to_i}"))
  end

  def decr(key, val = 1)
    to_i_if_digits(request(key, "decr #{k(key)} #{val.to_i}"))
  end

  # alist plugin commands

  def alist_at(key, index)
    request(key, "alist_at #{k(key)} #{index}", nil, :value_list_receiver)[0]
  end

  def alist_clear(key)
    request(key, "alist_clear #{k(key)}")
  end

  def alist_delete(key, value)
    request_with_value(key, "alist_delete #{k(key)}", value)
  end

  def alist_delete_at(key, index)
    request(key, "alist_delete_at #{k(key)} #{index}")
  end

  def alist_empty?(key)
    request(key, "alist_empty? #{k(key)}")
  end

  def alist_first(key)
    request(key, "alist_first #{k(key)}", nil, :value_list_receiver)[0]
  end

  def alist_last(key)
    request(key, "alist_last #{k(key)}", nil, :value_list_receiver)[0]
  end

  def alist_pop(key)
    request(key, "alist_pop #{k(key)}", nil, :value_list_receiver)[0]
  end

  def alist_shift(key)
    request(key, "alist_shift #{k(key)}", nil, :value_list_receiver)[0]
  end

  def alist_gets(key, range = nil)
    count_and_values(request(key, with_range("alist_gets #{k(key)}", range), nil, :value_list_receiver))
  end

  def alist_gets_with_time(key, range = nil)
    count_and_values(request(key, with_range("alist_gets_with_time #{k(key)}", range), nil, :value_list_receiver))
  end

  def alist_join(key, sep, range = nil)
    cmd = with_range("alist_join #{k(key)} #{sep.bytesize}", range)
    count_and_values(request(key, cmd, sep, :value_list_receiver))
  end

  def alist_join_with_time(key, sep, range = nil)
    cmd = with_range("alist_join_with_time #{k(key)} #{sep.bytesize}", range)
    count_and_values(request(key, cmd, sep, :value_list_receiver))
  end

  def alist_to_json(key, range = nil)
    request(key, with_range("alist_to_json #{k(key)}", range), nil, :value_list_receiver)[0]
  end

  def alist_to_s(key, range = nil)
    ret = request(key, with_range("alist_to_s #{k(key)}", range), nil, :value_list_receiver)
    return nil if ret.empty?
    ret[0] = ret[0].to_i
    ret[1] = eval(ret[1])
    ret
  end

  def alist_include?(key, value)
    request(key, "alist_include? #{k(key)} #{value.bytesize}", value)
  end

  def alist_index(key, value)
    ret = request_with_value(key, "alist_index #{k(key)}", value)
    return nil if ret == 'nil'
    to_i_if_digits(ret)
  end

  def alist_length(key)
    to_i_if_digits(request(key, "alist_length #{k(key)}"))
  end

  def alist_insert(key, index, value)
    request_with_value(key, "alist_insert #{k(key)} #{index}", value)
  end

  def alist_sized_insert(key, array_size, value)
    request_with_value(key, "alist_sized_insert #{k(key)} #{array_size}", value)
  end

  def alist_swap_and_insert(key, value)
    request_with_value(key, "alist_swap_and_insert #{k(key)}", value)
  end

  def alist_swap_and_sized_insert(key, array_size, value)
    request_with_value(key, "alist_swap_and_sized_insert #{k(key)} #{array_size}", value)
  end

  def alist_expired_swap_and_insert(key, expt, value)
    request_with_value(key, "alist_expired_swap_and_insert #{k(key)} #{expt}", value)
  end

  def alist_expired_swap_and_sized_insert(key, expt, array_size, value)
    request_with_value(key, "alist_expired_swap_and_sized_insert #{k(key)} #{expt} #{array_size}", value)
  end

  def alist_push(key, value)
    request_with_value(key, "alist_push #{k(key)}", value)
  end

  def alist_sized_push(key, array_size, value)
    request_with_value(key, "alist_sized_push #{k(key)} #{array_size}", value)
  end

  def alist_swap_and_push(key, value)
    request_with_value(key, "alist_swap_and_push #{k(key)}", value)
  end

  def alist_swap_and_sized_push(key, array_size, value)
    request_with_value(key, "alist_swap_and_sized_push #{k(key)} #{array_size}", value)
  end

  def alist_expired_swap_and_push(key, expt, value)
    request_with_value(key, "alist_expired_swap_and_push #{k(key)} #{expt}", value)
  end

  def alist_expired_swap_and_sized_push(key, expt, array_size, value)
    request_with_value(key, "alist_expired_swap_and_sized_push #{k(key)} #{expt} #{array_size}", value)
  end

  def alist_update_at(key, index, value)
    request_with_value(key, "alist_update_at #{k(key)} #{index}", value)
  end

  # map plugin commands

  def map_set(key, mapkey, value, expt = 0)
    request_with_value(key, "map_set #{k(key)} #{mapkey} 0 #{expt}", value)
  end

  def map_get(key, mapkey)
    request(key, "map_get #{k(key)} #{mapkey}", nil, :value_list_receiver)[0]
  end

  def map_delete(key, mapkey)
    request(key, "map_delete #{k(key)} #{mapkey}")
  end

  def map_clear(key)
    request(key, "map_clear #{k(key)}")
  end

  def map_size(key)
    to_i_if_digits(request(key, "map_size #{k(key)}"))
  end

  def map_key?(key, mapkey)
    to_bool(request(key, "map_key? #{k(key)} #{mapkey}"))
  end

  def map_value?(key, value)
    to_bool(request_with_value(key, "map_value? #{k(key)}", value))
  end

  def map_empty?(key)
    to_bool(request(key, "map_empty? #{k(key)}"))
  end

  def map_keys(key)
    count_and_values(request(key, "map_keys #{k(key)}", nil, :value_list_receiver))
  end

  def map_values(key)
    count_and_values(request(key, "map_values #{k(key)}", nil, :value_list_receiver))
  end

  def map_to_s(key)
    request(key, "map_to_s #{k(key)}", nil, :value_list_receiver)[0]
  end

  # mapcount plugin commands

  def mapcount_get(key, sub_keys = nil)
    mapcount('mapcount_get', key, sub_keys, 0, :json)
  end

  def mapcount_get_ms(key, sub_keys = nil)
    mapcount('mapcount_get_ms', key, sub_keys, 0, :marshal)
  end

  def mapcount_countup(key, sub_keys, expt = 0)
    mapcount('mapcount_countup', key, sub_keys, expt, :json)
  end

  def mapcount_countup_ms(key, sub_keys, expt = 0)
    mapcount('mapcount_countup_ms', key, sub_keys, expt, :marshal)
  end

  def mapcount_update(key, sub_keys = nil, expt = 0)
    mapcount('mapcount_update', key, sub_keys, expt, :json)
  end

  def mapcount_update_ms(key, sub_keys = nil, expt = 0)
    mapcount('mapcount_update_ms', key, sub_keys, expt, :marshal)
  end

  private

  def k(key)
    "#{key}\e#{@default_hash_name}"
  end

  def store(cmd, key, val, expt, raw)
    val = Marshal.dump(val) unless raw
    request(key, "#{cmd} #{k(key)} 0 #{expt.to_i} #{val.bytesize}", val)
  end

  def request_with_value(key, cmd, value)
    raise 'value must be a String object.' unless value.instance_of?(String)
    request(key, "#{cmd} #{value.bytesize}", value)
  end

  def mapcount(cmd, key, sub_keys, expt, format)
    sub_keys_str =
      case sub_keys
      when String then sub_keys
      when Array then sub_keys.join(',')
      when Hash then sub_keys.map { |sk, v| "#{sk}:#{v}" }.join(',')
      else ''
      end
    ret = request(key, "#{cmd} #{k(key)} #{expt.to_i} #{sub_keys_str.bytesize}", sub_keys_str, :value_list_receiver)
    return nil if ret.empty?
    res = format == :marshal ? Marshal.load(ret[0]) : JSON.parse(ret[0])
    res['last_updated_date'] = Time.parse(res['last_updated_date']) if res['last_updated_date']
    res
  end

  def with_range(cmd, range)
    range ? "#{cmd} #{range}" : cmd
  end

  def count_and_values(ret)
    return nil if ret.empty?
    ret[0] = ret[0].to_i
    ret
  end

  def to_i_if_digits(ret)
    ret =~ /\A\d+\z/ ? ret.to_i : ret
  end

  def to_bool(ret)
    case ret
    when 'true' then true
    when 'false' then false
    else ret
    end
  end

  def request(key, cmd, value = nil, receiver = :oneline_receiver)
    nid, _d = @rttable.search_node(key)
    send_command(nid, cmd, value, receiver)
  end

  def send_command(nid, cmd, value = nil, receiver = :oneline_receiver)
    retries = 0
    begin
      ret = Timeout.timeout(TIMEOUT_SEC) do
        con = connection(nid)
        con.write(value ? "#{cmd}\r\n#{value}\r\n" : "#{cmd}\r\n")
        __send__(receiver, con)
      end
    rescue SystemCallError, IOError
      close_connection(nid)
      retry if (retries += 1) < RETRY_COUNT
      raise
    rescue Timeout::Error
      close_connection(nid)
      raise
    end
    raise ret if ret.is_a?(String) && ret.start_with?('SERVER_ERROR', 'CLIENT_ERROR')
    ret
  end

  def fetch_routing_data(nid)
    Timeout.timeout(TIMEOUT_SEC) do
      con = connection(nid)
      con.write("routingdump\r\n")
      len = con.gets.to_i
      return nil if len <= 0
      rd = Marshal.load(read_bytes(con, len))
      read_bytes(con, 2) # "\r\n"
      con.gets # "END\r\n"
      rd
    end
  rescue SystemCallError, IOError, Timeout::Error
    close_connection(nid)
    nil
  end

  def connection(nid)
    self.class.connections[nid] ||= begin
      host, port = nid.split(/[:_]/)
      TCPSocket.new(host, port)
    end
  end

  def close_connection(nid)
    con = self.class.connections.delete(nid)
    con.close if con
  rescue IOError
  end

  def oneline_receiver(con)
    ret = con.gets
    raise 'connection closed' if ret.nil?
    ret.chomp
  end

  def multiplelines_receiver(con)
    ret = []
    while (line = con.gets) != "END\r\n"
      raise 'connection closed' if line.nil?
      ret << line.chomp
    end
    ret
  end

  def value_list_receiver(con)
    ret = []
    each_value(con) do |s, val|
      return s.join(' ') if error_line?(s)
      ret << val
    end
    ret
  end

  def value_hash_receiver(con)
    ret = {}
    each_value(con) do |s, val|
      return s.join(' ') if error_line?(s)
      ret[s[1]] = val
    end
    ret
  end

  def value_casid_receiver(con)
    ret = []
    each_value(con) do |s, val|
      return s.join(' ') if error_line?(s)
      ret << val << s[4]
    end
    ret
  end

  # Yields each "VALUE <key> <flags> <bytes> [<casid>]" header and its data.
  # An error line is yielded with nil as data.
  def each_value(con)
    while (line = con.gets) != "END\r\n"
      raise 'connection closed' if line.nil?
      s = line.split(' ')
      if error_line?(s)
        yield s, nil
        next
      end
      val = read_bytes(con, s[3].to_i)
      read_bytes(con, 2) # "\r\n"
      yield s, val
    end
  end

  def error_line?(s)
    s[0] == 'SERVER_ERROR' || s[0] == 'CLIENT_ERROR'
  end

  def read_bytes(con, len)
    ret = con.read(len)
    raise 'connection closed' if ret.nil? || ret.bytesize != len
    ret
  end
end
