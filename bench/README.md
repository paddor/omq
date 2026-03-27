# Benchmarks

Measured with `benchmark-ips` on Linux x86_64, Ruby 4.0.2 +YJIT (epoll).

## Throughput (push/pull, msg/s)

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 64 B | 244k | 47k | 36k |
| 256 B | 230k | 45k | 33k |
| 1024 B | 232k | 43k | 32k |
| 4096 B | 227k | 38k | 32k |

## Latency (req/rep roundtrip)

| | inproc | ipc | tcp |
|---|---|---|---|
| roundtrip | 9 µs | 47 µs | 61 µs |

## io_uring

With `liburing-dev` installed, io-event uses io_uring instead of epoll.
Inproc throughput jumps to **~340k msg/s** — a ~40% improvement.
IPC and TCP are within variance.

```sh
# Debian/Ubuntu
sudo apt install liburing-dev
gem pristine io-event
```

## Running

```sh
ruby --yjit bench/throughput.rb
ruby --yjit bench/latency.rb
```
