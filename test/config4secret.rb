# The config of the servers that the tests of config.cluster_secret start.
Roma.configure do |config|
  config.data_copy.stream_copy_wait = 0.0001
  config.cluster_secret = 'the secret of the test cluster'
end
