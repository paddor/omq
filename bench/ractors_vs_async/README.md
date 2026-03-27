# Ractors vs Async

OMQ works with both Async fibers (single-threaded concurrency) and Ractors
(true parallelism). This benchmark measures when each approach wins.

## Setup

```
producer → PUSH/PULL → 4 workers → PUSH/PULL → collector
```

Each worker receives a 64 B message, computes `fib(28)` (~2 ms of CPU
work per message), and forwards the result. The producer fires all
messages at once; the collector waits for all of them.

- **Async**: 4 fibers in one thread, connected via IPC (unix sockets)
- **Ractors**: 4 Ractors in separate threads, connected via IPC (abstract namespace)

## Results (Ruby 4.0.2 +YJIT, Linux x86_64)

### With CPU work (~2 ms per message)

| | Workers | Throughput | Total time | Speedup |
|---|---------|-----------|-----------|---------|
| Async (1 thread) | 4 fibers | 108 msg/s | 9.3s | 1.0x |
| Ractors (4 threads) | 4 Ractors | 286 msg/s | 3.5s | **2.7x** |

Near-linear scaling: 4 cores → 2.7x speedup (the remainder is
transport overhead).

### Without CPU work (pure forwarding)

| | Workers | Throughput | Speedup |
|---|---------|-----------|---------|
| Async (1 thread, ipc) | 4 fibers | 9.8k msg/s | **1.0x** |
| Ractors (4 threads, ipc) | 4 Ractors | 3.6k msg/s | 0.4x |

Without CPU work, Async wins — fiber switching is cheaper than
cross-Ractor IPC.

## When to use Ractors

**Use Ractors when your workers do CPU-heavy processing:**
- Image/video encoding
- Compression (zlib, zstd)
- Cryptography (hashing, signing)
- Parsing large payloads (JSON, Protobuf, XML)
- Mathematical computation
- ML inference

In these cases, the work per message dominates the transport overhead.
4 Ractors ≈ 4 cores ≈ ~4x throughput (minus transport overhead).

**Use Async when your workers are I/O-bound or do light processing:**
- Message routing and forwarding
- Database queries (waiting on network)
- HTTP API calls
- Logging, metrics, filtering
- Light transforms (string manipulation, field extraction)

Async fibers have near-zero scheduling overhead — no thread context
switches, no Ractor isolation costs, and they can use `inproc://` for
sub-µs in-process messaging.

## The rule of thumb

If a worker spends **more time computing than waiting**, use Ractors.
If it spends **more time waiting than computing**, use Async.

Most real-world services are I/O-bound. Start with Async. Move to
Ractors only when profiling shows CPU saturation on one core.

## Running

```sh
ruby --yjit bench/ractors_vs_async/bench.rb async
ruby --yjit bench/ractors_vs_async/bench.rb ractors
```
