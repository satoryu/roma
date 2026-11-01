require_relative 'config4cpdb_base'

Roma.configure { |config| config.storage.engine = :sqlite3 }
