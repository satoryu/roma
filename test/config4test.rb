# The config of the servers that the tests start.
Roma.configure do |config|
  config.data_copy.stream_copy_wait = 0.0001
end
