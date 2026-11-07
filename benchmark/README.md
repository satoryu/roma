# Benchmarks

## set_get.rb
Measures `set` and `get` on a ROMA node with each storage engine (hash, groonga, sqlite3 and dbm), and on Redis, and writes the results as a Markdown table.

For each target it starts a server in a temporary directory, sets keys from client processes, gets the same keys and stops the server. A ROMA node runs alone with redundancy 1, so it does no replication, and Redis keeps nothing on disk. The clients talk to ROMA and to Redis with the same small socket code, so only the servers differ.

### Setup
It needs `redis-server` and the libraries of the storage engines. With Homebrew:

```
brew install redis groonga gdbm
gem install gdbm -- --with-gdbm-dir=$(brew --prefix gdbm)
BUNDLE_GEMFILE=benchmark/Gemfile bundle install
```

### Run
```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb
```

| Option | Default | |
|---|---|---|
| `-t`, `--targets` | `hash,groonga,sqlite3,dbm,redis` | Targets to measure |
| `-c`, `--clients` | 4 | Client processes, each with its own connection |
| `-n`, `--requests` | 10000 | Requests of each command from each client |
| `-s`, `--value-size` | 100 | Size of the values in bytes |
| `-w`, `--warmup` | 1000 | Sets before measuring |
| `-p`, `--port` | 21300 | Port of the servers |
| `--redis-server` | `redis-server` | redis-server to run |
| `--keep` | | Keep the directories of the servers, with their output |

A ROMA node takes about 10 seconds to start: it takes only its system commands until it has checked the other nodes.

The clients run on the same machine as the server, so a fast server can be limited by them. Try more clients (`-c`) to see whether the numbers still grow.
