# CURVE Benchmark Results

Measured on Linux x86_64, Ruby 4.0.1 (no JIT), using `benchmark-ips`.
Compare with the [plain OMQ benchmarks](../../bench/).

## Latency (REQ/REP roundtrip)

| Transport | NULL | CURVE | Overhead |
|-----------|------|-------|----------|
| ipc | 113 µs | 195 µs | +72% |
| tcp | 136 µs | 236 µs | +74% |

## Throughput (PUSH/PULL, msg/s)

| Transport | Message size | NULL | CURVE | Overhead |
|-----------|-------------|------|-------|----------|
| ipc | 64 B | 25.5k/s | 16.4k/s | −36% |
| ipc | 256 B | 25.2k/s | 15.6k/s | −38% |
| ipc | 1024 B | 24.3k/s | 13.9k/s | −43% |
| ipc | 4096 B | 17.0k/s | 10.2k/s | −40% |
| tcp | 64 B | 20.2k/s | 13.2k/s | −35% |
| tcp | 256 B | 20.6k/s | 12.7k/s | −38% |
| tcp | 1024 B | 20.6k/s | 11.9k/s | −42% |
| tcp | 4096 B | 14.3k/s | 8.8k/s | −39% |

## Notes

Each message passes through two `crypto_box` operations (encrypt on send,
decrypt on receive) via libsodium/rbnacl FFI. The ~70% latency overhead and
~35–40% throughput cost is dominated by the FFI call overhead rather than
the crypto itself.

## Running

```sh
cd omq-curve
bundle exec ruby bench/latency.rb
bundle exec ruby bench/throughput.rb
```
