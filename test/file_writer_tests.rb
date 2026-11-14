require 'logger'
require 'roma/write_behind'

module FileWriterTests
  # making and writing test
  def test_wb_write
    system('rm -rf wb_test')
    fw = Roma::WriteBehind::FileWriter.new('wb_test', 1024 * 1024, Logger.new(nil), node_id: 'roma0_11211')
    path = "wb_test/roma0_11211/roma/#{Time.now.strftime('%Y%m%d')}/"

    assert(!File.exist?("#{path}/0.wb"))
    100.times do |i|
      fw.write('roma', i, "key-#{i}", "val-#{i}")
    end
    assert(File.exist?("#{path}/0.wb"))
    assert(!File.exist?("#{path}/1.wb"))

    fw.rotate('roma')

    i = 100
    fw.write('roma', i, "key-#{i}", "val-#{i}")
    assert(File.exist?("#{path}/1.wb"))

    fw.close_all

    wb0 = read_wb("#{path}/0.wb")
    assert_equal(100, wb0.length)
    wb0.each do |_last, cmd, key, val|
      assert_equal("key-#{cmd}", key)
      assert_equal("val-#{cmd}", val)
    end
    wb1 = read_wb("#{path}/1.wb")
    assert_equal(1, wb1.length)
  end

  # rotation test per data
  def test_wb_rotation
    system('rm -rf wb_test')
    fw = Roma::WriteBehind::FileWriter.new('wb_test', 900, Logger.new(nil), node_id: 'roma0_11211')
    path = "wb_test/roma0_11211/roma/#{Time.now.strftime('%Y%m%d')}/"

    100.times do |i|
      fw.write('roma', 0,
               format('key-%04d', i),
               format('val-%04d', i))
    end

    assert(File.exist?("#{path}/0.wb"))
    assert(File.exist?("#{path}/1.wb"))
    assert(File.exist?("#{path}/2.wb"))
    assert(File.exist?("#{path}/3.wb"))
    assert(!File.exist?("#{path}/4.wb"))
  end

  # rotation test per time
  def test_rotation2
    system('rm -rf wb_test')
    fw = Roma::WriteBehind::FileWriter.new('wb_test', 1024 * 1024, Logger.new(nil), node_id: 'roma0_11211')
    path = "wb_test/roma0_11211/roma/#{Time.now.strftime('%Y%m%d')}/"

    # rottime's usec have some value,from instance was created
    rt = fw.instance_eval { @rotation_time }
    assert_not_equal(0, rt.hour + rt.min + rt.sec + rt.usec)
    # formatting execute in today's date
    assert_equal(Time.now.day, rt.day)
    # confirming the file do not exist
    assert(!File.exist?("#{path}/0.wb"))
    fw.write('roma', 1, 'key', 'val')
    # Open when somenthing to write,and in same timing rottime is updated
    rt = fw.instance_eval { @rotation_time }
    # In this time, under of date become "0"
    assert_equal(0, rt.hour + rt.min + rt.sec + rt.usec)
    # date become tomorrow
    assert_not_equal(Time.now.day, rt.day)
    10.times do |i|
      fw.write('roma', i, "key-#{i}", "val-#{i}")
    end
    # confirming file is only 1 not over 2
    assert(File.exist?("#{path}/0.wb"))
    assert(!File.exist?("#{path}/1.wb"))

    # set rottime to now forcibly
    fw.instance_eval { @rotation_time = Time.now }
    # confriming to change rottime
    assert_not_equal(rt, fw.instance_eval { @rotation_time })
    # When something write, rotation is occured
    fw.write('roma', 1, 'key', 'val')
    assert(File.exist?("#{path}/1.wb"))
    # rottime turn back because of test shold not step over the day.
    assert_equal(rt, fw.instance_eval { @rotation_time })
  end

  # rotation test from outside
  def test_wb_rotation3
    system('rm -rf wb_test')
    fw = Roma::WriteBehind::FileWriter.new('wb_test', 1024 * 1024, Logger.new(nil), node_id: 'roma0_11211')
    path = "wb_test/roma0_11211/roma/#{Time.now.strftime('%Y%m%d')}/"

    # confirming file don't exist
    assert(!File.exist?("#{path}/0.wb"))
    10.times do |i|
      fw.write('roma', i, "key-#{i}", "val-#{i}")
    end
    # confirming file is only 1 not over 2
    assert(File.exist?("#{path}/0.wb"))
    assert(!File.exist?("#{path}/1.wb"))

    fw.rotate('roma')
    10.times do |i|
      fw.write('roma', i, "key-#{i}", "val-#{i}")
    end
    # confirming files are 2 not over 3
    assert(File.exist?("#{path}/0.wb"))
    assert(File.exist?("#{path}/1.wb"))
    assert(!File.exist?("#{path}/2.wb"))

    # test of do rotation continuously
    fw.rotate('roma')
    fw.rotate('roma')
    fw.rotate('roma')
    # confimring file's count are still 2 (not changing).
    assert(File.exist?("#{path}/0.wb"))
    assert(File.exist?("#{path}/1.wb"))
    assert(!File.exist?("#{path}/2.wb"))
    10.times do |i|
      fw.write('roma', i, "key-#{i}", "val-#{i}")
    end
    # confirming files are 3 not over 4
    assert(File.exist?("#{path}/0.wb"))
    assert(File.exist?("#{path}/1.wb"))
    assert(File.exist?("#{path}/2.wb"))
    assert(!File.exist?("#{path}/3.wb"))
  end

  def test_current_file_path
    system('rm -rf wb_test')
    fw = Roma::WriteBehind::FileWriter.new('wb_test', 900, Logger.new(nil), node_id: 'roma0_11211')

    assert_nil(fw.current_file_path('roma'))

    fw.write('roma', 0, 'key', 'val')

    path = File.expand_path("./wb_test/roma0_11211/roma/#{Time.now.strftime('%Y%m%d')}/")
    assert_equal(File.join(path, '0.wb'), fw.current_file_path('roma'))

    fw.rotate('roma')
    assert_nil(fw.current_file_path('roma'))

    fw.write('roma', 0, 'key', 'val')
    assert_equal(File.join(path, '1.wb'), fw.current_file_path('roma'))
  end

  def test_path
    system('rm -rf wb_test')
    fw = Roma::WriteBehind::FileWriter.new('wb_test', 900, Logger.new(nil), node_id: 'roma0_11211')
    path = File.expand_path('./wb_test/roma0_11211/roma')
    assert_equal(path, fw.path('roma'))
  end

  def read_wb(fname)
    ret = []
    open(fname, 'rb') do |f|
      until f.eof?
        b1 = f.read(10)
        last, cmd, klen = b1.unpack('NnN')
        key = f.read(klen)
        b2 = f.read(4)
        vlen = b2.unpack1('N')
        val = f.read(vlen)
        ret << [last, cmd, key, val]
      end
    end
    ret
  end
end
