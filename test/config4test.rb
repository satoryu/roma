# The config of the romads that the tests start.
Roma.configure do |config|
  config.data_copy.stream_copy_wait_param = 0.0001
  config.plugins = ['plugin_storage.rb', 'plugin_alist.rb', 'plugin_map.rb', 'plugin_mapcount.rb']
end
