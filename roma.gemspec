lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib)

require 'roma/version'

Gem::Specification.new do |s|
  s.authors = ["Junji Torii", "Hiroki Matsue", "Hiroaki Iwase"]
  s.homepage = 'http://roma-kvs.org/'
  s.name = "roma"
  s.version = Roma::VERSION
  s.license = 'GPL-3.0-only'
  s.summary = "ROMA server"
  s.description = <<-EOF
    ROMA is one of the data storing systems for distributed key-value stores. It is a completely decentralized distributed system that consists of multiple processes, called nodes, on several machines. It is based on pure P2P architecture like a distributed hash table, thus it provides high availability and scalability.
  EOF
  s.files = Dir[
    '[A-Z]*',
    'bin/**/*',
    'lib/**/*',
    'test/**/*.rb',
    'spec/**/*.rb',
    'doc/**/*',
    'examples/**/*',
  ]

  # The storage gems need Ruby 3.4 or later.
  s.required_ruby_version = '>= 3.4'

  # Use these for libraries.
  s.require_path = 'lib'

  # Use these for applications.
  s.bindir = "bin"
  s.executables = Dir.entries('bin').reject{ |d| d =~ /^\.+$/ || d =~ /^sample_/ }

  s.rdoc_options = [
                '--line-numbers',
                '--inline-source',
                "--main", "README.md",
                "-c UTF-8"
               ]
  s.extra_rdoc_files = ["README.md", "ChangeLog.md"]

  s.add_dependency 'eventmachine', '~> 1.2.7'
  s.add_dependency 'jaro_winkler', '~> 1.7'
  s.add_dependency 'roma-storage', '~> 0.1.0'
  s.add_dependency 'logger'
  s.add_dependency 'thor', '~> 1.3'
  s.add_dependency 'readline'
  #s.add_dependency 'levenshtein', '~> 0.2.2'

  s.add_development_dependency 'ffi'
  s.add_development_dependency 'test-unit'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'irb'
  s.add_development_dependency 'simplecov', '~> 1.3'
  s.add_development_dependency 'simplecov-cobertura', '~> 4.0'
end
