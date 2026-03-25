# Benchmarks

Measured with `benchmark-ips` on Linux x86_64, Ruby 4.0.1 +YJIT.

## Throughput (push/pull, msg/s)

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 64 B | 177k | 40k | 32k |
| 256 B | 160k | 35k | 30k |
| 1024 B | 157k | 37k | 29k |
| 4096 B | 150k | 22k | 19k |

## Latency (req/rep roundtrip)

| | inproc | ipc | tcp |
|---|---|---|---|
| roundtrip | 16 µs | 74 µs | 112 µs |

## Running

```sh
ruby --yjit bench/throughput.rb
ruby --yjit bench/latency.rb
```
