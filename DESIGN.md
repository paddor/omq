# OMQ Design

Pure Ruby implementation of ZMTP 3.1 (the ZeroMQ wire protocol) on top of
Ruby's Fiber::Scheduler and the Async ecosystem.

## Why

ZeroMQ is built on a set of hard-won lessons about networked systems.
The "fallacies of distributed computing" (Deutsch/Gosling, 1994) assume
that the network is reliable, latency is zero, bandwidth is infinite,
topology doesn't change, and transport cost is zero. Every ZMQ mechanism
exists to handle the reality that none of this is true:

| Fallacy | ZMQ / OMQ response |
|---|---|
| The network is reliable | Auto-reconnect with backoff; linger drain on close |
| Latency is zero | Async send queues decouple producers from consumers |
| Bandwidth is infinite | High-water marks (HWM) bound queue depth per connection |
| The network is secure | CURVE encryption (libsodium, via omq-curve gem) |
| Topology doesn't change | Bind/connect separation; peers come and go freely |
| There is one administrator | No broker required; any topology works peer-to-peer |
| Transport cost is zero | Batched writes reduce syscalls; inproc skips the kernel; optional Zstd compression |
| The network is homogeneous | ZMTP is a wire protocol; interop with libzmq, nanomsg, etc. |

OMQ brings all of this to Ruby without C extensions or FFI.

## Layers

```
+----------------------+
|    Application       |  OMQ::PUSH, OMQ::SUB, etc.
+----------------------+
|    Socket            |  send / receive / bind / connect
+----------------------+
|    Engine            |  connection lifecycle, reconnect, linger
+----------------------+
|    Routing           |  PUSH round-robin, PUB fan-out, REQ/REP, ...
+----------------------+
|    Connection        |  ZMTP handshake, heartbeat, framing
+----------------------+
|    Transport         |  TCP, IPC (Unix), inproc (in-process)
+----------------------+
|  io-stream + Async   |  buffered IO, Fiber::Scheduler
+----------------------+
```

## Task tree

Every socket spawns a tree of Async tasks. All tasks are **transient** --
they don't prevent the reactor from exiting when user code finishes.

```
Async (user code)
|-- tcp accept tcp://...              per bind endpoint
|-- conn tcp://... [accepted]         per accepted peer
|   |-- heartbeat                     PING/PONG keepalive
|   |-- recv pump                     conn -> recv_queue (or reaper for write-only)
|   +-- (subscription listener)       PUB/RADIO: reads SUBSCRIBE/JOIN commands
|-- conn tcp://... [connected]        per outgoing peer
|   |-- heartbeat
|   +-- recv pump
|-- send pump                         singleton, shared across all connections
+-- reconnect tcp://...               outgoing endpoint retry loop
```

**Per-connection subtree.** Each connection gets its own task whose children
are the heartbeat, recv pump (or reaper), and any protocol listeners. When
the connection dies, the entire subtree is cleaned up by Async. No orphaned
tasks, no reparenting.

**Send pump is socket-level.** The send pump is a singleton -- one per socket,
not per connection. It dequeues from the routing strategy's send queue and
round-robins (or fans out) across all live connections. It outlives individual
connections.

**Reaper tasks.** Write-only sockets (PUSH, SCATTER) have no recv pump.
Instead, a "reaper" task calls `receive_message` which blocks until the peer
disconnects, then triggers `connection_lost`. Without it, a dead peer is only
detected on the next send.

## Engine lifecycle

```
bind/connect
  |
  v
[accepting / reconnecting]  <---+
  |                             |
  v                             |
connection_made                 |
  |-- handshake (ZMTP 3.1)      |
  |-- start heartbeat           |
  |-- register with routing     |
  +-- start recv pump / reaper  |
  |                             |
  v                             |
[running]                       |
  |                             |
  v                             |
connection_lost ----------------+  (auto-reconnect if enabled)
  |
  v
close
  |-- stop listeners (if connections exist)
  |-- linger: drain send queues (keep listeners if no peers yet)
  |-- stop remaining listeners
  |-- close all connections
  +-- stop routing + reconnect tasks
```

**Linger.** On close, send queues are drained for up to `linger` seconds.
If no peers are connected, listeners stay open so late-arriving peers can
still receive queued messages. `linger=0` closes immediately.

**Reconnect.** Failed or lost connections are retried with configurable
interval (default 100ms). Supports exponential backoff via a Range
(e.g., `0.1..5.0`). Suppressed during close (`@closing` flag).

## Send pump batching

The send pump reduces syscalls by batching:

```
1. Blocking dequeue (wait for first message)
2. Non-blocking drain up to 64 more messages
3. Write batch to connections (buffered, no flush)
4. Flush each connection once
```

Under light load, batch size is 1 -- no overhead. Under burst load (producer
faster than consumer), the batch grows and flushes are amortized:
`N_msgs * N_conns` syscalls become `N_conns` per cycle.

For fan-out (PUB/RADIO), one published message is written to all matching
subscribers before flushing -- so N subscribers see 1 flush each, not N
flushes per message.

## ZMTP 3.1 wire protocol

OMQ implements the full ZMTP 3.1 specification:

**Greeting** (64 bytes): version negotiation, security mechanism, as-server flag.

**Frames**: 1-byte flags (MORE, LONG, COMMAND) + size + body. Short frames
use 1-byte size (max 255); long frames use 8-byte big-endian size.

**Commands**: READY (handshake properties), SUBSCRIBE/CANCEL (PUB/SUB),
JOIN/LEAVE (RADIO/DISH), PING/PONG (heartbeat with TTL).

**Security**: NULL (no auth) built-in. CURVE (NaCl/libsodium encryption)
via the `omq-curve` gem. The mechanism is pluggable -- set `socket.mechanism`
before connecting.

## Transports

**TCP** -- standard network sockets. Bind auto-selects port with `:0`.

**IPC** -- Unix domain sockets. Supports file-based paths and Linux abstract
namespace (`ipc://@name`). File sockets are cleaned up on unbind.

**inproc** -- in-process. Connects two engines via DirectPipe objects.
No ZMTP framing, no kernel. Message parts are frozen strings passed
as Ruby arrays through the send queue and recv queue (two hops, same
as TCP/IPC). The fast path sets `direct_recv_queue` on the peer's
DirectPipe so the send pump enqueues directly into the peer's recv
queue instead of going through a Connection. Subscription commands
(PUB/SUB, RADIO/DISH) flow through separate Async::Queues.

All TCP and IPC connections are wrapped in `IO::Stream::Buffered` which
provides `read_exactly(n)` for reading ZMTP frames and buffered writes
for batch flushing.

## Socket types

| Pattern | Send | Receive | Routing |
|---|---|---|---|
| PUSH/PULL | round-robin | fair-queue | load balancing |
| PUB/SUB | fan-out (prefix match) | subscribe filter | publish/subscribe |
| REQ/REP | round-robin + envelope | envelope-based reply | request/reply |
| DEALER/ROUTER | round-robin / identity | fair-queue / identity | async req/rep |
| PAIR | exclusive 1:1 | exclusive 1:1 | bidirectional |
| CLIENT/SERVER | round-robin | identity-based reply | async client/server |
| RADIO/DISH | fan-out (group match) | join filter | group messaging |
| SCATTER/GATHER | round-robin | fair-queue | like PUSH/PULL |
| PEER/CHANNEL | identity-based | fair-queue | peer-to-peer |

XPUB/XSUB are like PUB/SUB but expose subscription events to the application.

## Dependencies

- **async** -- Fiber::Scheduler reactor, tasks, promises, queues
- **io-stream** -- buffered IO wrapper (read_exactly, flush, connection errors)
- **io-event** -- low-level event loop (epoll/io_uring/kqueue)

Optional: **omq-curve** for CURVE encryption, **msgpack** and **zstd-ruby**
for the CLI's msgpack format and compression.

## CLI (`omq`)

The `omq` executable is a command-line tool for any OMQ socket type.
It reads from stdin, sends messages, receives messages, and writes to stdout.
Supports all socket types, formats (ascii, quoted, jsonl, msgpack, raw),
CURVE encryption, Zstandard compression, Ruby eval (`-e`), and require (`-r`).

See `omq --help` for usage, `omq --examples` for annotated examples.
