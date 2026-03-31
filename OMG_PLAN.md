# Plan: omg — Pure Ruby NNG (Scalability Protocols) + CLI

## Context

OMQ is a pure-Ruby ZMQ implementation with a powerful CLI. The goal is to build the equivalent for NNG (nanomsg-next-gen): a pure-Ruby implementation of the Scalability Protocols (SP) wire protocol, with a CLI that matches OMQ's power and adds built-in benchmarking to compare omg vs omq vs nngcat.

Two gems: `protocol-nng` (wire protocol, zero deps) and `omg` (sockets + routing + CLI).
Repos at `/home/roadster/dev/oss/protocol-nng` and `/home/roadster/dev/oss/omg`.

## SP Wire Protocol (vs ZMTP)

**Much simpler than ZMTP.** The entire wire protocol is:
- **Handshake**: 8 bytes — `0x00 0x53 0x50 0x00` magic + 2-byte protocol type ID + 2 reserved bytes
- **Messages**: 64-bit big-endian length prefix + body. No flags, no MORE, no commands.
- **Protocol headers** (REQ/REP request IDs, etc.) are part of the message body, managed by the routing layer.

Key differences from ZMTP:
- Single messages (String), not multi-frame (Array<String>)
- No SUBSCRIBE/CANCEL commands — PUB sends everything, SUB filters locally
- No PING/PONG heartbeat — rely on TCP keepalive
- No security mechanism in the protocol — TLS at transport level (Ruby stdlib OpenSSL)
- No identity/routing-id concept in the wire protocol

## Gem 1: protocol-nng

**Location**: `/home/roadster/dev/oss/protocol-nng`
**Zero runtime dependencies.**

```
protocol-nng/
  protocol-nng.gemspec
  Gemfile
  lib/
    protocol/
      nng.rb
      nng/
        version.rb
        error.rb
        protocol_id.rb         # Constants: PAIR0=0x0010, PUB0=0x0020, SUB0=0x0021, REQ0=0x0030, REP0=0x0031, PUSH0=0x0050, PULL0=0x0051, etc.
        valid_peers.rb         # Compatibility matrix (12 entries vs ZMTP's 18+)
        codec.rb
        codec/
          handshake.rb         # Encode/decode 8-byte SP TCP handshake
          message.rb           # Encode/decode 64-bit length-prefixed messages
        connection.rb          # Handshake + send_message(String) / receive_message -> String
  test/
    codec/
      handshake_test.rb
      message_test.rb
    connection_test.rb
    valid_peers_test.rb
```

**Public API:**
```ruby
conn = Protocol::NNG::Connection.new(io, protocol_id: Protocol::NNG::ProtocolId::PUSH0)
conn.handshake!                    # Exchange 8 bytes, validate peer
conn.send_message("hello")        # Write length-prefixed message
body = conn.receive_message        # Read length-prefixed message -> String
```

**Protocol IDs** — need to verify exact encoding against NNG C source (`nng/src/sp/protocol/`). Format is `(protocol_number << 4) | version_and_role`. Will validate via nngcat interop tests.

## Gem 2: omg

**Location**: `/home/roadster/dev/oss/omg`
**Dependencies**: `protocol-nng`, `async ~> 2.38`, `io-stream ~> 0.11`

```
omg/
  omg.gemspec
  Gemfile
  exe/omg
  lib/
    omg.rb
    omg/
      version.rb
      socket.rb                # Base class: bind/connect/close/send/receive
      readable.rb              # #receive -> String (not Array)
      writable.rb              # #send(String), #<< (not Array)

      # Socket types (initial: core 4 patterns)
      pair.rb                  # OMG::PAIR0
      req_rep.rb               # OMG::REQ0, OMG::REP0
      pub_sub.rb               # OMG::PUB0, OMG::SUB0
      push_pull.rb             # OMG::PUSH0, OMG::PULL0

      sp/
        options.rb             # tls_context, subscribe_prefixes, survey_timeout, etc.
        engine.rb              # Connection lifecycle, reconnect (adapted from OMQ::ZMTP::Engine)
        reactor.rb             # Async task management (from OMQ)
        routing.rb             # Strategy dispatcher
        routing/
          round_robin.rb       # Mixin (adapted for single messages)
          pair.rb              # Exclusive 1:1
          req.rb               # Round-robin + 32-bit request ID header
          rep.rb               # Fair-queue + request ID backtrace routing
          pub.rb               # Pure fan-out (no subscription tracking — simpler than OMQ!)
          sub.rb               # Fair-queue + client-side prefix filtering
          push.rb              # Round-robin
          pull.rb              # Fair-queue
        transport/
          tcp.rb               # From OMQ, use Protocol::NNG::Connection
          ipc.rb               # From OMQ
          tls.rb               # NEW: OpenSSL::SSL over TCP, URI scheme tls+tcp://
          inproc.rb            # From OMQ (later phase)

      cli.rb                   # Option parser, runner dispatch
      cli/
        config.rb
        formatter.rb           # Formats: ascii, quoted, raw, jsonl, msgpack, marshal
        base_runner.rb         # Shared runner logic (TLS instead of CURVE)
        push_pull.rb
        pub_sub.rb
        req_rep.rb
        pair.rb
        pipe.rb                # PULL -> eval -> PUSH with Ractor parallelism
        bench.rb               # NEW: `omg bench` command

  bench/
    throughput.rb              # In-process PUSH/PULL benchmark
    latency.rb                 # In-process REQ/REP roundtrip
    compare.rb                 # omg vs omq vs nngcat side-by-side
  test/
    ...
```

### Key Architectural Differences from OMQ

| Aspect | OMQ (ZMQ) | omg (NNG) |
|--------|-----------|-----------|
| Messages | Multi-frame `Array<String>` | Single `String` |
| PUB/SUB filtering | Publisher-side (SUBSCRIBE commands) | Subscriber-side (local prefix match) |
| REQ/REP routing | Empty delimiter frame envelope | 32-bit request ID in message body |
| Security | CURVE mechanism in protocol | TLS at transport level |
| Heartbeat | ZMTP PING/PONG commands | TCP keepalive (no protocol-level) |
| Identity | Wire-level identity in READY | No wire-level identity |
| Socket types | 20 (incl. draft) | 8 initially, 12 total later |

### CLI: "on steroids"

All OMQ CLI features carry over (adapted for single messages):
- `-c`/`-b`, `-D`/`-F`, formats, `-e`/`-E` eval, `-r` require, `-P` Ractor workers
- `--subscribe`, timing flags, `--compress`, `--transient`, `--echo`
- `pipe` virtual type

**NNG-specific additions:**
- `--tls-cert FILE`, `--tls-key FILE`, `--tls-cacert FILE`, `--tls-no-verify`
- `omg bench` subcommand with `--compare` flag

**`omg bench` command:**
```
omg bench [options]
  --pattern throughput|latency   (default: throughput)
  --transport tcp|ipc|tls+tcp    (default: tcp)
  --size BYTES                   (default: 64, repeatable)
  --duration SECS                (default: 5)
  --warmup SECS                  (default: 1)
  --compare                      Also run omq + nngcat for side-by-side comparison
  --json                         Machine-readable output
```

Comparison mode shells out to `omq` and `nngcat` with equivalent parameters, collects timing data, and prints a table:

```
--- throughput (64B, tcp) ---
omg:    185,000 msgs/s   11.3 MB/s
omq:    140,000 msgs/s    8.5 MB/s
nngcat:  95,000 msgs/s    5.8 MB/s
```

### What to Reuse from OMQ (adapt, not copy verbatim)

- `Engine` lifecycle (reconnect, linger, close) — `/home/roadster/dev/oss/omq/lib/omq/zmtp/engine.rb`
- `Reactor` task management — `/home/roadster/dev/oss/omq/lib/omq/zmtp/reactor.rb`
- `RoundRobin` send pump batching — `/home/roadster/dev/oss/omq/lib/omq/zmtp/routing/round_robin.rb`
- `Transport::TCP` bind/connect/accept — `/home/roadster/dev/oss/omq/lib/omq/zmtp/transport/tcp.rb`
- `Transport::IPC` — `/home/roadster/dev/oss/omq/lib/omq/zmtp/transport/ipc.rb`
- CLI architecture (Config, Formatter, BaseRunner, runners) — `/home/roadster/dev/oss/omq/lib/omq/cli/`
- PipeRunner with Ractor parallelism — `/home/roadster/dev/oss/omq/lib/omq/cli/pipe.rb`

## Implementation Order

### Phase 1: protocol-nng
1. Scaffold gem (gemspec, version, error)
2. `ProtocolId` constants — verify against NNG C source
3. `Codec::Handshake` — encode/decode 8-byte handshake
4. `Codec::Message` — encode/decode length-prefixed messages
5. `ValidPeers` — compatibility matrix
6. `Connection` — handshake + message I/O
7. **Interop test with nngcat** (critical validation)

### Phase 2: omg core (PUSH/PULL first)
8. Scaffold gem, adapt `Reactor`, `Options`
9. `Transport::TCP` — adapted from OMQ
10. `Routing::RoundRobin`, `Routing::Push`, `Routing::Pull`
11. `Engine` — adapted from OMQ
12. `Socket`, `Readable`, `Writable` — single-message API
13. `OMG::PUSH0`, `OMG::PULL0`
14. **Interop: OMG::PUSH0 -> nngcat --pull, nngcat --push -> OMG::PULL0**

### Phase 3: Remaining core socket types
15. `Routing::Pair` + `OMG::PAIR0`
16. `Routing::Req`, `Routing::Rep` + `OMG::REQ0`, `OMG::REP0` (32-bit request ID headers)
17. `Routing::Pub`, `Routing::Sub` + `OMG::PUB0`, `OMG::SUB0` (client-side filtering)
18. Interop tests for each against nngcat

### Phase 4: TLS transport
19. `Transport::TLS` — OpenSSL::SSL wrapping TCP
20. Interop test with nngcat over `tls+tcp://`

### Phase 5: CLI
21. `exe/omg`, option parser, Config, Formatter
22. `BaseRunner` + `PushRunner`, `PullRunner`
23. Remaining runners: ReqRunner, RepRunner, PubRunner, SubRunner, PairRunner
24. `PipeRunner` with Ractor support
25. TLS CLI options

### Phase 6: Benchmarks
26. `bench/throughput.rb`, `bench/latency.rb`
27. `omg bench` CLI command
28. `--compare` mode (shells out to omq + nngcat)

### Phase 7: Later additions
29. `Transport::IPC`, `Transport::Inproc`
30. SURVEYOR/RESPONDENT, BUS socket types
31. DESIGN.md, CLI.md

## Verification

1. **Unit tests**: Each protocol-nng codec class, each routing strategy
2. **Interop tests**: Every socket type against nngcat (the ground truth)
3. **End-to-end**: `omg push -c tcp://... | omg pull -b tcp://...`
4. **TLS**: Self-signed cert round-trip, interop with nngcat TLS
5. **Benchmarks**: `omg bench --compare` produces valid comparison data
6. **CLI parity**: All OMQ CLI features work (eval, pipe, formats, compression)
