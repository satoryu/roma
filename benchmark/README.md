# Benchmarks

## set_get.rb
Measures `set` and `get` on a ROMA node with each storage engine (hash, groonga, sqlite3 and dbm), and on Redis, and writes the results as Markdown tables: how fast, and how much memory and disk the server uses for the keys.

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
| `--yjit` | `off` | Run the ROMA nodes with YJIT: `off`, `on` or `both` |
| `--keep` | | Keep the directories of the servers, with their output |

### Server CPU
The first table also tells the CPU time (user and system, from `ps`) that the server used for a request. ops/s depends on whether the clients keep the server busy, while this doesn't, so it shows better how much work a request costs the server.

### YJIT
`--yjit both` runs each ROMA node twice, without and with YJIT, as `hash` and `hash+yjit` and so on. Redis runs once, and the clients are the same.

```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb --yjit both -c 16
```

With few clients the node waits for them, and ops/s hardly changes even if YJIT makes the node faster. Compare the server CPU per request, or use enough clients (`-c`) to keep the node busy.

### Memory and disk
The second table tells, for each target, the resident memory (RSS) of the server before and after the sets, the growth per key, and the disk space of the storage files after the sets.

- RSS includes the pages of the files that the server maps and has touched, such as the files of groonga.
- The disk space is the blocks that the files take. groonga allocates large files in advance, so it is large even for a few keys.
- Few keys tell little about the memory: the growth is within the noise of Ruby's heap. Measure with many keys.

### Many keys
The keys are `--clients` x `--requests`. For example, 4 clients x 250000 requests set and get 1,000,000 keys:

```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb -t hash,groonga,dbm,redis -n 250000
```

sqlite3 sets about 2,000 keys a second, so leave it out of large runs, or give it fewer keys in a run of its own.

### Notes
A ROMA node takes about 10 seconds to start: it takes only its system commands until it has checked the other nodes.

The clients run on the same machine as the server, so a fast server can be limited by them. Try more clients (`-c`) to see whether the numbers still grow.
