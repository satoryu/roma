require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'fake_kvs'
require 'roma/tools/safecopy_test'

class SafecopyTestTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  # Changes the statuses of the files as a node, when it is asked.
  class FakeAdmin
    attr_reader :requests, :statuses
    attr_accessor :reply

    def initialize(divnum)
      @statuses = [:normal] * divnum
      @requests = []
      @reply = 'PUSHED'
    end

    def request(_nid, cmd)
      @requests << cmd
      _, n, status, _hname = cmd.split
      @statuses[n.to_i] = status == 'safecopy' ? :safecopy_flushed : :normal if @reply == 'PUSHED'
      @reply
    end

    def command(_nid, cmd)
      ["storages[roma].storage.divnum #{@statuses.size}", "storages[roma].storage.safecopy_stats #{@statuses.inspect}", 'END']
        .tap { @last_stats = cmd }
    end
  end

  def setup
    super
    @kvs = fake_kvs
    @admin = FakeAdmin.new(2)
    @out = StringIO.new
  end

  def safecopy_test(**opts)
    kvs = @kvs
    Roma::Tools::SafecopyTest.new(kvs.nid, out: @out, admin: @admin, wait: 0,
                                  client: -> { Roma::Tools::TextClient.new([kvs.nid]) }).run(**opts)
  end

  def test_run
    assert_equal 0, safecopy_test(keys: 5)
    assert_equal ['set_storage_status 0 safecopy roma', 'set_storage_status 0 normal roma',
                  'set_storage_status 1 safecopy roma', 'set_storage_status 1 normal roma'], @admin.requests
    assert_equal [:normal, :normal], @admin.statuses
    assert_equal 10, @kvs.data.keys.grep(/\A(flushing|caching)_key_\d\z/).size
    assert_match(/\A1th test =+\n1th file \*+\n  \[:safecopy_flushed, :normal\]\n  \[:normal, :normal\]\n2th file/, @out.string)
  end

  def test_count
    safecopy_test(keys: 1, count: 2)
    assert_equal 8, @admin.requests.size
    assert_match(/^2th test/, @out.string)
  end

  # The keys are checked against what the writer has set. The client that
  # checks the caching keys, made after the two writers and the check of the
  # flushing keys, gets a wrong value.
  def test_wrong_value
    kvs = @kvs
    made = 0
    client = lambda do
      made += 1
      Roma::Tools::TextClient.new([kvs.nid]).tap do |c|
        next unless made == 4
        def c.get(key)
          key == 'caching_key_0' ? 'wrong' : super
        end
      end
    end
    errors = Roma::Tools::SafecopyTest.new(kvs.nid, out: @out, admin: @admin, wait: 0, client: client).run(keys: 2)
    assert_equal 1, errors
    assert_match(/^error k=caching_key_0 "wrong" \(expected \d+\)$/, @out.string)
  end

  def test_refused
    @admin.reply = 'CLIENT_ERROR storage[0] != :normal status'
    assert_raise_message('set_storage_status 0 safecopy: CLIENT_ERROR storage[0] != :normal status') do
      safecopy_test(keys: 1)
    end
    assert_equal 10, @admin.requests.size
  end

  def test_no_hash
    @admin.define_singleton_method(:command) { |_nid, _cmd| ['END'] }
    assert_raise_message("#{@kvs.nid} has no roma.") { safecopy_test(keys: 1) }
  end
end

class SafecopyWriterTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
  end

  def writer(keys)
    Roma::Tools::SafecopyTest::Writer.new(Roma::Tools::TextClient.new([@kvs.nid]), 'k', keys)
  end

  # The keys before the last one set have the round, and the others the
  # round before.
  def test_expected
    w = writer(3)
    w.instance_variable_set(:@round, 4)
    w.instance_variable_set(:@done, 1)
    assert_equal %w(4 4 3), (0..2).map { |i| w.expected(i) }
    w.instance_variable_set(:@done, 2)
    assert_equal %w(4 4 4), (0..2).map { |i| w.expected(i) }
  end

  def test_rounds
    w = writer(3).start
    assert_equal 1, w.wait_round
    assert_equal 2, w.wait_round
    w.stop
    assert_equal (0..2).map { |i| w.expected(i) }, (0..2).map { |i| @kvs.data["k_#{i}"] }
  end

  # The key that isn't stored is tried again, until it is stopped.
  def test_stop_while_retrying
    @kvs.replies['set'] = "NOT_STORED\r\n"
    w = writer(1).start
    sleep 0.3
    w.stop
    assert_operator @kvs.commands.size, :>, 1
    assert_equal '0', w.expected(0)
  end

  def test_thread_died
    w = writer(1)
    w.instance_variable_get(:@client).define_singleton_method(:set) { |*| raise ArgumentError, 'broken' }
    w.start
    assert_raise_message('broken') { w.wait_round }
  end
end
