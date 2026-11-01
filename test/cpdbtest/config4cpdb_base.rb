# The config of the romads that test_other_cpdb.rb starts, but the storage.
Roma.configure do |config|
  config.data_copy.stream_copy_wait = 0.0001
  config.plugins = ['plugin_storage.rb', 'plugin_alist.rb', 'plugin_map.rb', 'plugin_mapcount.rb']
end
