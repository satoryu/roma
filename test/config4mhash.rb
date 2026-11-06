# The config of the servers that test_multi_hash.rb starts.
Roma.configure do |config|
  config.data_copy.stream_copy_wait = 0.0001
end
