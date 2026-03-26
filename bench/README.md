# Benchmarks

Measured with `benchmark-ips` on Linux x86_64, Ruby 4.0.2 +YJIT (epoll).

## Throughput (push/pull, msg/s)

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 64 B | 145k | 40k | 32k |
| 256 B | 146k | 42k | 25k |
| 1024 B | 142k | 41k | 26k |
| 4096 B | 167k | 37k | 26k |

## Latency (req/rep roundtrip)

| | inproc | ipc | tcp |
|---|---|---|---|
| roundtrip | 15 µs | 62 µs | 88 µs |

## io_uring

With `liburing-dev` installed, io-event uses io_uring instead of epoll.
Inproc throughput jumps to **223k msg/s** (9.5 µs latency) — a 54% improvement.
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
