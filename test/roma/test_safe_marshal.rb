require 'test_helper'
require 'roma/safe_marshal'

class SafeMarshalTest < Test::Unit::TestCase
  data('alist' => [%w(a b), [1, 2]],
       'empty alist' => [[], []],
       'map' => { 'k' => 'v' },
       'mapcount' => { 'c' => 3, 'last_updated_date' => '2026-01-01T00:00:00 +00' },
       'encoded and long strings' => [['é', 'x' * 300], [2**40, -70_000]],
       'nil, float and symbols' => [nil, 1.5, :sym, :sym])
  def test_load(value)
    assert_equal value, Roma::SafeMarshal.load(Marshal.dump(value))
  end

  # The same String twice is dumped with a link to it.
  def test_load_with_a_link_to_a_string
    s = 'same'
    assert_equal [[s, s], [1, 1]], Roma::SafeMarshal.load(Marshal.dump([[s, s], [1, 1]]))
  end

  BadStruct = Struct.new(:a)

  # A value that links to an Array: its inspect and join take 2**40 steps.
  def self.blow_up
    a = ['x']
    40.times { a = [a, a] }
    [[a], []]
  end

  data('object' => [[[Object.new], []], /type "o"/],
       'struct' => [BadStruct.new(1), /type "S"/],
       'regexp' => [[[/x/], []], %r{type "/"}],
       'class' => [[[String], []], /type "c"/],
       'hash with a default' => [Hash.new(1).merge('a' => 1), /type "}"/],
       'too deep' => [[[[[1]]]], /nested too deep/],
       'blow up' => [blow_up, /nested too deep/])
  def test_load_rejects(data)
    value, message = data
    assert_raise_message(message) { Roma::SafeMarshal.load(Marshal.dump(value)) }
  end

  # Containers that link to another are refused even when shallow.
  def test_load_rejects_a_link_to_a_container
    a = %w(x)
    dump = Marshal.dump([a, a])
    assert_raise_message('link to a container') { Roma::SafeMarshal.load(dump) }
  end

  data('empty' => '', 'not Marshal' => 'value', 'cut' => Marshal.dump([%w(a b), [1, 2]])[0..-3])
  def test_load_rejects_broken_data(data)
    assert_raise(Roma::SafeMarshal::Error) { Roma::SafeMarshal.load(data) }
  end
end
