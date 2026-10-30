require 'test_helper'

# End-to-end tests for the mapcount plugin through romad.
# Each command's behavior is covered by test_mapcountplugin_command.rb.
class MapCountPluginTest < Test::Unit::TestCase
  self.test_order = :defined
  include RomaTestUtils

  DATE_FORMAT = "%Y-%m-%dT%H:%M:%S +00"

  def setup
    start_roma
    @rc=RomaTestClient.new(["localhost_11211","localhost_11212"])
    @k = "key1"
    @sk = "subkey1"
    @lt = Time.parse(Time.now.strftime(DATE_FORMAT))
    @ret = {"last_updated_date"=>@lt, @sk=>1}
  end

  def teardown
    stop_roma
  end

  def check_roma_value(h, res)
    h.each{|k, v|
      if k == 'last_updated_date'
        assert_equal true, res[k].between?(v, v+1)
      else
        assert_equal v, res[k]
      end
    }
  end

  def test_mapcount_get(n = 5)
    n.times do |i|
      @sk = "subkey#{i}"
      expt = i
      
      retc = {"last_updated_date"=>@lt}
      (i+1).times do |j|
        retc["subkey#{j}"] = 1
      end
      check_roma_value(retc, @rc.mapcount_countup(@k, @sk, 0))
      
      retg = {"last_updated_date"=>@lt}
      retg["subkey#{i}"] = 1
      check_roma_value(retg, @rc.mapcount_get(@k, @sk))
      check_roma_value(retc, @rc.mapcount_get(@k))
    end

    ret2 = {"last_updated_date"=>@lt, "subkey0"=>1, "subkey1"=>1}
    check_roma_value(ret2, @rc.mapcount_get(@k, 'subkey0,subkey1'))
  end

  def test_mapcount_get_ms(n = 5)
    n.times do |i|
      @sk = "subkey#{i}"
      expt = i
      
      retc = {"last_updated_date"=>@lt}
      (i+1).times do |j|
        retc["subkey#{j}"] = 1
      end
      check_roma_value(retc, @rc.mapcount_countup_ms(@k, @sk, 0))

      retg = {"last_updated_date"=>@lt}
      retg["subkey#{i}"] = 1
      check_roma_value(retg, @rc.mapcount_get_ms(@k, @sk))
      check_roma_value(retc, @rc.mapcount_get_ms(@k))
    end

    ret2 = {"last_updated_date"=>@lt, "subkey0"=>1, "subkey1"=>1}
    check_roma_value(ret2, @rc.mapcount_get_ms(@k, 'subkey0,subkey1'))
  end

end #MapCountPluginTest
