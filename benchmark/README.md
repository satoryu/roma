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
| `--pipeline` | 1 | Requests that a client sends at once, such as `1,4,16` |
| `--rate` | | Send the requests at this many a second in all, on a schedule |
| `--profile` | | Record where the ROMA nodes spend their time in a directory |
| `--stackprof` | | With `--profile`, run StackProf too: `cpu` (default) or `object` |
| `--keep` | | Keep the directories of the servers, with their output |

### Server CPU
The first table also tells the CPU time (user and system, from `ps`) that the server used for a request. ops/s depends on whether the clients keep the server busy, while this doesn't, so it shows better how much work a request costs the server.

### YJIT
`--yjit both` runs each ROMA node twice, without and with YJIT, as `hash` and `hash+yjit` and so on. Redis runs once, and the clients are the same.

```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb --yjit both -c 16
```

With few clients the node waits for them, and ops/s hardly changes even if YJIT makes the node faster. Compare the server CPU per request, or use enough clients (`-c`) to keep the node busy.

### Pipeline
By default a client sends a request after the reply of the last one, so the server waits for the event loop, reads and writes for every request. `--pipeline 16` makes each client send 16 requests at once and then read the 16 replies: the server reads them together and writes the replies together, so it costs the server less for a request. A list measures each depth in turn on the same server, and the later sets overwrite the keys of the first.

```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb --pipeline 1,4,16,64
```

The latencies are those of the requests sent together, so they grow with the depth. The memory and disk table is from the sets of the first depth.

### Rate
By default a client sends a request after the reply of the last one. If the server pauses, such as for GC, each client waits for only one request, so the pause hardly shows in the percentiles, only in the max. Many independent clients don't wait for each other: all the requests that come during the pause wait.

`--rate 20000` makes the clients send 20,000 requests a second in all, each when it is due, and measures each latency from when it was due, not from when it was sent. A request that a late reply delays waits as long as it would have with independent clients, so the percentiles show the pauses.

```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb -t hash,redis -n 250000 --rate 20000
```

Give a rate below what the server can do: if ops/s is below the rate, the server doesn't keep up, and the latencies grow until the end. With `--pipeline`, a client sends a batch when it is due, so the rate is of the requests, not of the batches.

### Profile
`--profile DIR` loads `profiler.rb` into the ROMA nodes and records where a node spends its time while each command is measured, in files named after the target, the command and the pipeline, such as `hash-get-p1`:

```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/set_get.rb -t hash --pipeline 1,16 --profile profile
```

- `summary.md`: the user and system CPU time for a request, how the main thread, which runs the event loop and handles the requests, spent its time, and the objects that the node allocated and its GC for a request, from `GC.stat`.
- `.sample.txt`: the native stacks of all the threads of the node, every millisecond, from macOS's `sample`. Without `sample`, `--profile` records the rest without the stacks.
- `.sample.md`: its summary by `sample_report.rb`. For each thread that did more than wait, it tells the share of the time in each kind of work, and the functions where the thread was most. `ruby benchmark/sample_report.rb FILE` summarizes a `.sample.txt` again.

| Kind | |
|---|---|
| waiting for events | In select, waiting for requests: the node was idle |
| waiting for the GVL | Ready to run, waiting for another Ruby thread to release the GVL |
| blocked | Waiting for something else, such as a queue or sleep |
| socket I/O | In read and writev, on the sockets |
| GC | Collecting garbage |
| other system calls | In the other functions of the kernel |
| running | In Ruby, EventMachine and the libraries |

The shares are of the time, not of the CPU time. A main thread that waits for events much is idle: the clients don't keep it busy.

With `--stackprof`, the node also runs StackProf, and `.stackprof.txt` tells its Ruby methods. `stackprof` reads the `.stackprof.dump` for more, such as `stackprof --method 'String#split' FILE` for the callers of a method.

- `--stackprof` or `--stackprof cpu` samples the methods that use the CPU. In a node, it puts most of the time in `EventMachine.run_machine`, also that of the requests, which run in a Fiber. For the Ruby methods of the requests, use `request_path.rb`. It interrupts the node with a signal every 200 microseconds, so it slows the node more than `sample`.
- `--stackprof object` records the methods that allocate each object. It keeps every allocation, so the node is slow and large, and only the objects and their methods tell much.

Profiling slows the node a little, so compare the numbers of runs with the same options.

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

## request_path.rb
Measures the Ruby code that a ROMA node runs for set and get, without the sockets and the event loop. It makes a node in its own process, as `roma server` does, and gives the requests to a connection's `receive_data`, as EventMachine does, so the dispatcher, the commands and the storage run as in a node. It tells the CPU time and the objects for a request.

```
BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/request_path.rb --pipeline 16 --stackprof wall --out profile
```

| Option | Default | |
|---|---|---|
| `-e`, `--engine` | `hash` | Storage engine |
| `-n`, `--requests` | 100000 | Requests of each command |
| `-s`, `--value-size` | 100 | Size of the values in bytes |
| `--pipeline` | 1 | Requests given to `receive_data` at once |
| `--stackprof` | | Record the methods with StackProf: `cpu`, `wall` or `object`, in `set.stackprof.dump` and `get.stackprof.dump` with their `.txt` |
| `--out` | `.` | Where `--stackprof` writes |

Use `wall` rather than `cpu` for the methods: `cpu` puts much of the time of the requests, which run in a Fiber, in the methods that run after it. Nothing else runs in the process, so the wall time is the CPU time. `stackprof --method 'Roma::CommandPlugin::Storage#ev_get' get.stackprof.dump` tells the time of each line of a method.

The difference from the server CPU of `set_get.rb` is what the node spends on the sockets and in EventMachine.

With the hash engine, the keys and values are Ruby objects, so a node with more keys takes longer to collect garbage. A set writes a new value into a large Hash, and the next minor GC marks the whole Hash again: about 60 ms for each minor GC with 1,000,000 keys, during which the node handles no requests. groonga and dbm keep the data outside Ruby's heap and don't have this.
