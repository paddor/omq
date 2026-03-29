# Benchmarks

Measured with `benchmark-ips` on Linux x86_64, Ruby 4.0.2 +YJIT (epoll).

## Throughput (push/pull, msg/s)

```
┌──────┐       ┌──────┐
│ PUSH │──────→│ PULL │
└──────┘       └──────┘
```

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 64 B | 229k | 48k | 36k |
| 256 B | 228k | 42k | 32k |
| 1024 B | 233k | 41k | 33k |
| 4096 B | 229k | 37k | 31k |

## Latency (req/rep roundtrip)

```
┌─────┐  req   ┌─────┐
│ REQ │───────→│ REP │
│     │←───────│     │
└─────┘  rep   └─────┘
```

| | inproc | ipc | tcp |
|---|---|---|---|
| roundtrip | 10 µs | 50 µs | 62 µs |

## io_uring

With `liburing-dev` installed, io-event uses io_uring instead of epoll.
Inproc throughput jumps to **~340k msg/s** — a ~40% improvement.
IPC and TCP are within variance.

```sh
# Debian/Ubuntu
sudo apt install liburing-dev
gem pristine io-event
```

## Burst throughput (push/pull and pub/sub, msg/s)

Under burst load (1000-message bursts), the send pump batches writes
before flushing — reducing syscalls from `N_msgs × N_conns` to `N_conns`
per cycle.

### PUSH/PULL

| Transport | msg/s |
|-----------|-------|
| ipc | 165k |
| tcp | 173k |

### PUB/SUB fan-out

| Transport | 1 sub | 5 subs | 10 subs |
|-----------|-------|--------|---------|
| ipc | 189k | 42k | 21k |
| tcp | 178k | 45k | 19k |

## Running

```sh
ruby --yjit bench/throughput.rb
ruby --yjit bench/latency.rb
ruby --yjit bench/flush_batching/bench.rb
```
