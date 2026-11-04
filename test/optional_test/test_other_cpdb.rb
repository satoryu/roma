require 'test_helper'
require 'roma/messaging/con_pool'
require 'roma/configuration'
require 'pathname'

if ENV['OPTIONAL']
  class OtherCpdbTest < Test::Unit::TestCase
    self.test_order = :defined
    include RomaTestUtils

    def teardown
      stop_roma
    rescue StandardError => e
      puts "#{e} #{$@}"
    end
  end

  # Dbm Storage Test
  class OtherCpdbDbmTest < OtherCpdbTest
    def setup
      start_roma 'cpdbtest/config4cpdb_dbm.rb'
      @rc = RomaTestClient.new(%w(localhost_11211 localhost_11212))
      @sock = TCPSocket.new('localhost', 11_211)
    end

    def test_st_class_dbm
      @sock.write("stat st_class\r\n")
      assert_equal('storages[roma].storage.st_class DbmStorage', @sock.gets.chomp)
      assert_equal('END', @sock.gets.chomp)
    end
  end

  # Sqlite3 Storage Test
  class OtherCpdbSqlite3Test < OtherCpdbTest
    def setup
      start_roma 'cpdbtest/config4cpdb_sqlite3.rb'
      @rc = RomaTestClient.new(%w(localhost_11211 localhost_11212))
      @sock = TCPSocket.new('localhost', 11_211)
    end

    def test_st_class_sqlite3
      @sock.write("stat st_class\r\n")
      assert_equal('storages[roma].storage.st_class SQLite3Storage', @sock.gets.chomp)
      assert_equal('END', @sock.gets.chomp)
    end
  end
end
