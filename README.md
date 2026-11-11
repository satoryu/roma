# ROMA - A Distributed Key-Value Store in Ruby 
[![Gitter](https://badges.gitter.im/roma/roma.svg)](https://gitter.im/roma/roma?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge)
[![test](https://github.com/roma/roma/actions/workflows/test.yml/badge.svg)](https://github.com/roma/roma/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/satoryu/roma/branch/dev2_0/graph/badge.svg)](https://codecov.io/gh/satoryu/roma)

ROMA is one of the data storing systems for distributed key-value stores.  
It is a completely decentralized distributed system that consists of multiple
processes, called nodes, on several machines. It is based on pure P2P architecture  
like a distributed hash table, thus it provides high availability and scalability.

ROMA is written in Ruby. However, following choices are available to
access to ROMA.

* Client libraries of Ruby and Java are available.
* ROMA protocol is compatible with memcached text-based one so that  
  any memcached client libraries allows users to interact with ROMA.

More information is [here](http://roma-kvs.org/ "ROMA").

## Documentation

* Refer to [ROMA documentations](http://roma-kvs.org/ "ROMA")
* [Routing](docs/routing.md): what the routing files define, how nodes route keys, and how to set it up
* [Command plugins](docs/command_plugin.md): how the server runs plugin commands, and how to write your own

## Requirements
* Ruby >= 3.4



## Installation
### Install ROMA
You can simply install ROMA and dependency libralies by using a `gem` command of Ruby as follows.

```
$ gem install roma
```

### Make routing files

ROMA is required to make the routing files before starting up.  
The routing file is stored the routing information of each processes.

```
$ roma route create localhost_10001 localhost_10002 --replication-in-host
```

If succeeded, two new files which named localhost_10001.route.yml and localhost_10002.route.yml created in the current directory. See [Routing](docs/routing.md) for what they define.  
Refer to [Commands](http://roma-kvs.org/commands.html "Commands") for more detail information about Shell Commands.  

### Make a directory for a node
`roma new DIR` makes a directory to run a node in, as `rails new` does for an application: `config.rb`, a `Gemfile`, the routing table of a node, and the directories for the command plugins and the logs. The node runs in it at once:

```
$ roma new myroma
$ cd myroma
$ bundle install
$ bundle exec roma server localhost --config config.rb
```

The node is `localhost_12000` by default. `--address` and `--port` give another one, and `--storage` a storage engine, such as `--storage dbm`, whose gem is added to the `Gemfile`. `--dev` makes the `Gemfile` take ROMA from the directory of the `roma` command, instead of the released gem. To add nodes, make the routing tables again by `roma route create` in `routing`.

### Start up ROMA
Run two processes by `roma server` as follows:  

```
$ roma server localhost -p 10001 -d --replication-in-host
$ roma server localhost -p 10002 -d --replication-in-host
```

`roma server --help` shows the options.

`--pid-file PATH` writes the pid of the server to the file, and the server removes it when it stops, so that `kill $(cat PATH)` stops the server. `config.pid_file` sets it in the config file too. If the file has the pid of a running process, the server doesn't start.

```
$ roma server localhost -p 10001 -d --replication-in-host --pid-file localhost_10001.pid
$ kill $(cat localhost_10001.pid)
```

Refer to [Shell Commands](http://roma-kvs.org/commands.html#dist-jump-link-shell_commands) for more detail information about Shell Commands.  

### Choose a storage
ROMA keeps data in a Ruby Hash on memory by default. To keep data in files,
install one of the storage gems and set it in your config file.

| Storage | Gem | `config.storage.engine` |
| --- | --- | --- |
| Ruby Hash (default) | roma-storage (installed with ROMA) | `:hash` |
| DBM | [roma-storage-dbm](https://rubygems.org/gems/roma-storage-dbm) | `:dbm` |
| SQLite3 | [roma-storage-sqlite3](https://rubygems.org/gems/roma-storage-sqlite3) | `:sqlite3` |
| Groonga | [roma-storage-groonga](https://rubygems.org/gems/roma-storage-groonga) | `:groonga` |

Another storage gem works the same way: with roma-storage-NAME installed, `config.storage.engine = :NAME` requires `roma/storage/NAME` and uses the class in it named like `NAMEStorage`. `config.storage.engine` also takes a storage class.

roma-storage-groonga needs [Groonga](https://groonga.org/) 12.0.2 or later. Install it first, for example by `brew install groonga`.

For example, to use SQLite3:

```
$ gem install roma-storage-sqlite3
$ roma config create
```

Then edit the generated `config.rb`:

```ruby
Roma.configure do |config|
  config.storage.engine = :sqlite3
  config.storage.path = '/var/lib/roma'
  # ...
end
```

Start the server with the config file by `roma server localhost -p 10001 -d --config config.rb`.

### Configure the server
The config file sets the settings in `Roma.configure`. Each one has a default, so the file only needs what differs. A wrong value stops the server with a message such as `routing.lost_action should be one of :no_action, :auto_assign, :shutdown: :foo`.

```ruby
Roma.configure do |config|
  config.name = 'ROMA'
  config.port = 12000

  config.log.path = '/var/log/roma'
  config.log.level = :info

  config.routing.path = '/var/lib/roma'
  config.connection.pool.max = 10
  config.write_behind.path = '/var/lib/roma/wb'
end
```

The settings and their defaults are in [lib/roma/configuration.rb](lib/roma/configuration.rb). Without `--config`, the server runs with the defaults.

The command plugins need no settings: the server loads ROMA's plugins for data, and the `*.rb` files in `./command_plugins`. See [Command plugins](docs/command_plugin.md).

### Tools
The `roma` command has the tools to run ROMA, such as `roma route create`, `roma node send` and `roma storage recover-lost`. `roma help` lists the commands and the groups of them, `roma help GROUP` lists the commands of a group, such as `roma help route`, and `--help` after a command tells about it, such as `roma route create --help`.

## Usage
Like memcached, you can connect to ROMA with telnet. Connect to the ROMA process that you ran above.

```
$ telnet localhost 10001
```

You can interact with ROMA in the same way of memcached commands.

```
set foo 0 0 3 <return>
bar <return>
STORED
get foo <return>
VALUE foo 0 3
bar
END
```

Refer to [Commands](http://roma-kvs.org/commands.html "Commands") for more detail information about ROMA Commands.


## Contributing

If you would like to contribute, please...

1. Fork and git clone it.
2. Install gems required for development.
3. Make changes in a branch & add unit tests.
4. Run Unit Test
  * `bundle exec rake` (if unit test fails, run it again - it's fickle).
  * `bundle exec rake coverage` also measures the coverage of `lib`, including the server processes that the tests start. Open `coverage/index.html` for the report. CI uploads it to Codecov.
5. Run RuboCop by `bundle exec rubocop`. CI runs it on pull requests too. `bundle exec rubocop -a` corrects what it can safely. `.rubocop_todo.yml` lists the offenses that the code had when RuboCop came in; when you fix them in a file, remove the file from the list.
6. Create a pull request.

Contributions, improvements, comments and suggestions are welcome!

## Promoters
Roma is promoted by [Rakuten, Inc.](http://global.rakuten.com/corp/) and [Rakuten Institute of Technology](http://rit.rakuten.co.jp/).
