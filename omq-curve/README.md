# OMQ-CURVE

CurveZMQ ([RFC 26](https://rfc.zeromq.org/spec/26/)) encryption for [OMQ](https://github.com/paddor/omq). Adds Curve25519 authenticated encryption to any OMQ socket over tcp or ipc.

Interoperates with libzmq, CZMQ, pyzmq, and any other ZMTP 3.1 peer that speaks CURVE.

## Install

Requires libsodium on the system (the `rbnacl` gem calls it via FFI).

```sh
# Debian/Ubuntu
sudo apt install libsodium-dev

# macOS
brew install libsodium
```

```sh
gem install omq-curve
# or in Gemfile
gem 'omq-curve'
```

## Quick Start

```ruby
require 'omq-curve'
require 'async'

# Generate keypairs (once, store securely)
server_key = RbNaCl::PrivateKey.generate
client_key = RbNaCl::PrivateKey.generate

Async do |task|
  # --- Server ---
  rep = OMQ::REP.new
  rep.mechanism        = :curve
  rep.curve_server     = true
  rep.curve_public_key = server_key.public_key.to_s
  rep.curve_secret_key = server_key.to_s
  rep.bind('tcp://*:5555')

  task.async do
    msg = rep.receive
    rep << msg.map(&:upcase)
  end

  # --- Client ---
  req = OMQ::REQ.new
  req.mechanism        = :curve
  req.curve_server_key = server_key.public_key.to_s  # must know server's public key
  req.curve_public_key = client_key.public_key.to_s
  req.curve_secret_key = client_key.to_s
  req.connect('tcp://localhost:5555')

  req << 'hello'
  puts req.receive.inspect  # => ["HELLO"]
ensure
  req&.close
  rep&.close
end
```

## Key Generation

Keys are 32-byte Curve25519 keypairs. Generate them with rbnacl:

```ruby
require 'omq-curve'

key = RbNaCl::PrivateKey.generate

# Binary (32 bytes each) — use for socket options
key.public_key.to_s  # => "\xCC\xA9\x9F..." (32 bytes)
key.to_s             # => "\xAE\x8E\xC4..." (32 bytes)
```

### Persisting keys

Never store secret keys in plaintext in source control. Options:

```ruby
# Environment variables (hex-encoded)
ENV['OMQ_SERVER_SECRET'] = RbNaCl::Util.bin2hex(key.to_s)
# ... later ...
secret = RbNaCl::Util.hex2bin(ENV.fetch('OMQ_SERVER_SECRET'))

# Or use Z85 (ZeroMQ's printable encoding, 40 chars for 32 bytes)
z85_public = OMQ::Z85.encode(key.public_key.to_s)  # => "rq5+e..." (40 chars)
z85_secret = OMQ::Z85.encode(key.to_s)

# Decode back to binary
OMQ::Z85.decode(z85_public)  # => 32-byte binary string
```

### Key file convention

A simple pattern for file-based key storage:

```ruby
# Generate and save (once)
key = RbNaCl::PrivateKey.generate
File.write('server.key', OMQ::Z85.encode(key.to_s), perm: 0o600)
File.write('server.pub', OMQ::Z85.encode(key.public_key.to_s))

# Load
secret = OMQ::Z85.decode(File.read('server.key'))
public = OMQ::Z85.decode(File.read('server.pub'))
```

## Z85 Encoding

[Z85](https://rfc.zeromq.org/spec/32/) is ZeroMQ's printable encoding for binary keys. It uses an 85-character alphabet and produces 40 characters for a 32-byte key — safe for config files, environment variables, and CLI arguments.

```ruby
binary = RbNaCl::Random.random_bytes(32)
z85    = OMQ::Z85.encode(binary)   # => 40-char ASCII string
binary = OMQ::Z85.decode(z85)      # => 32-byte binary string
```

Z85 keys are compatible with libzmq's `zmq_curve_keypair()` output and tools like `curve_keygen`.

## Socket Options

| Option | Type | Description |
|--------|------|-------------|
| `mechanism` | `:null`, `:curve` | Security mechanism (default `:null`) |
| `curve_server` | Boolean | `true` for the CURVE server side |
| `curve_public_key` | String (32 bytes) | Our permanent public key |
| `curve_secret_key` | String (32 bytes) | Our permanent secret key |
| `curve_server_key` | String (32 bytes) | Server's public key (clients only) |
| `curve_authenticator` | Set, `#call`, nil | Client key authenticator (server only, see below) |

Set options before `bind`/`connect`:

```ruby
sock = OMQ::REP.new
sock.mechanism        = :curve
sock.curve_server     = true
sock.curve_public_key = public_key
sock.curve_secret_key = secret_key
sock.bind('tcp://*:5555')
```

## Client vs Server

In CURVE, "server" and "client" refer to the **cryptographic roles**, not the network topology. The CURVE server is the side that clients authenticate against.

- **CURVE server**: has a well-known public key that clients must know in advance. Typically the `bind` side, but not necessarily.
- **CURVE client**: knows the server's public key and proves its own identity during the handshake.

Any socket type can be either the CURVE server or client:

```ruby
# ROUTER as CURVE server (typical)
router = OMQ::ROUTER.new
router.mechanism    = :curve
router.curve_server = true
# ...

# PUB as CURVE server
pub = OMQ::PUB.new
pub.mechanism    = :curve
pub.curve_server = true
# ...
```

## Authentication

By default, any client that knows the server's public key can connect. Use `curve_authenticator` to restrict access.

### Allowlist (Set of keys)

```ruby
allowed = Set[client1_pub, client2_pub]

rep = OMQ::REP.new
rep.mechanism           = :curve
rep.curve_server        = true
rep.curve_public_key    = server_pub
rep.curve_secret_key    = server_sec
rep.curve_authenticator = allowed
rep.bind('tcp://*:5555')
```

Unauthorized clients are disconnected during the handshake — no READY is sent and no messages are exchanged.

### Custom authenticator (callable)

For dynamic lookups, logging, or rate limiting, pass anything that responds to `#call`:

```ruby
rep.curve_authenticator = ->(client_public_key) {
  # client_public_key is a 32-byte binary string
  db_lookup(client_public_key) || false
}
```

Return truthy to allow, falsy to reject. The authenticator runs during the CURVE handshake (after vouch verification, before READY), so rejected clients never reach the application layer.

### Loading keys from files

```ruby
allowed = Set.new(
  Dir['keys/clients/*.pub'].map { |f| OMQ::Z85.decode(File.read(f)) }
)
rep.curve_authenticator = allowed
```

### Note on ZAP

libzmq uses [ZAP (RFC 27)](https://rfc.zeromq.org/spec/27/) for authentication — an inproc REQ/REP protocol between the socket and a ZAP handler. OMQ skips this indirection and lets you pass the authenticator directly. The effect is the same: client keys are checked during the handshake.

## Managing Many Keys

### One keypair per service

The simplest model: each service has one keypair. Clients are configured with the server's public key. Key rotation means deploying a new keypair and updating all clients.

```ruby
# config/keys.yml (public keys only — safe to commit)
api_gateway: "rq5+eJ..."
worker_pool: "x8Kn2P..."
```

### Per-client keys with a key store

For finer-grained access control, give each client its own keypair and maintain a server-side allowlist:

```ruby
# Server-side key store (flat file, database, vault, etc.)
ALLOWED_CLIENTS = Set.new(
  File.readlines('authorized_keys.txt', chomp: true)
      .map { |z85| OMQ::Z85.decode(z85) }
)

rep.curve_authenticator = ALLOWED_CLIENTS
```

### Key rotation

CURVE's perfect forward secrecy means rotating the permanent keypair doesn't compromise past traffic — each connection uses ephemeral session keys that are destroyed on disconnect.

To rotate a server key:

1. Generate a new keypair
2. Configure the server with the new key
3. Update clients with the new server public key
4. Restart — new connections use the new key, existing connections continue with the old session keys until they disconnect

## Performance

CURVE adds ~70% latency overhead and ~35–40% throughput cost compared to NULL, dominated by libsodium FFI call overhead. See [bench/README.md](bench/README.md) for full results.

| | NULL | CURVE |
|---|---|---|
| Latency (ipc) | 113 µs | 195 µs |
| Throughput (ipc, 64 B) | 25.5k/s | 16.4k/s |

## Interoperability

OMQ-CURVE interoperates with any ZMTP 3.1 CURVE implementation. Verified against libzmq 4.3.5 via CZTop in both directions (OMQ↔libzmq) with REQ/REP and DEALER/ROUTER.

## How It Works

The [CurveZMQ](http://curvezmq.org/) handshake establishes a secure session in 4 steps:

1. **HELLO** — client sends its transient public key + proof it knows the server's key
2. **WELCOME** — server sends its transient public key in an encrypted cookie
3. **INITIATE** — client echoes the cookie + proves its permanent identity via a vouch
4. **READY** — server confirms, both sides have session keys

After the handshake, every ZMTP frame is encrypted as a CurveZMQ MESSAGE using Curve25519-XSalsa20-Poly1305 with strictly incrementing nonces.

Properties:
- **Perfect forward secrecy** — compromising permanent keys doesn't reveal past traffic
- **Server statelessness** — between WELCOME and INITIATE, the server holds no per-connection state (cookie-based recovery)
- **Anti-amplification** — HELLO (200 bytes) > WELCOME (168 bytes)
- **Replay protection** — strictly incrementing nonces, verified on every message

## License

[ISC](../LICENSE)
