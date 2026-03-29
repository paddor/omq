# omqcat Benchmarks

Measured on Linux x86_64, Ruby 4.0.2 +YJIT (io_uring).

## Throughput (PUSH/PULL, piping `seq N`)

```
                  stdin
                    │
┌───────────────────▼────────────────────┐
│  seq 10000 | omqcat push -c ipc://     │
└───────────────────┬────────────────────┘
                    │ IPC/TCP
┌───────────────────▼────────────────────┐
│  omqcat pull -b ipc:// > /dev/null     │
└────────────────────────────────────────┘
```

| Transport | msg/s |
|-----------|-------|
| tcp | 19k |
| ipc | 20k |

## Latency (REQ/REP, `-D "ping" -i 0`)

```
┌─────────────────────────────────────────┐
│  omqcat req -c ipc:// -D ping -i 0      │
└──────────────────┬──────────────────────┘
                   │  req/rep
┌──────────────────▼──────────────────────┐
│  omqcat rep -b ipc:// --echo            │
└─────────────────────────────────────────┘
```

| Transport | µs/roundtrip |
|-----------|-------------|
| tcp | 657 |
| ipc | 643 |

## Pipeline (4-worker fib)

```
┌──────────┐     ┌────────┐     ┌──────┐
│ producer │─TCP─│ worker │─TCP─│ sink │
│ PUSH     │     │ ×4     │     │ PULL │
└──────────┘     └────────┘     └──────┘
```

| N | msg/s |
|---|-------|
| 1000 | 288 |
| 5000 | 831 |

## Running

```sh
sh bench/omqcat/throughput.sh [count]   # default: 10000
sh bench/omqcat/latency.sh [count]      # default: 1000
sh bench/omqcat/pipeline.sh [count]     # default: 1000
```
