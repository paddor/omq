# Plan: Package omq as a Snap

## Context

omq-cli is a pure Ruby ZeroMQ CLI tool. Users currently need Ruby, Bundler, and manual gem installation to use it. A snap package bundles everything — Ruby interpreter, gems, native libraries — into a single installable unit. The goal is zero-dependency installation via `snap install omq`.

## Approach

Build Ruby 4.0.2 from source, `gem install` all deps from RubyGems, use `GEM_PATH` at runtime (no Bundler). `omq-cli` (and its dependency `omq`) are published on RubyGems.

## Files to Create

```
snap/
  snapcraft.yaml
  local/
    omq-wrapper.sh
```

## snapcraft.yaml

### Metadata & Apps

- `name: omq`, `base: core24`, `confinement: strict`
- Version sourced from omq-cli gem version
- One app: `omq` with wrapper script
- Plugs: `network`, `network-bind`, `home`

### Parts (4 parts, ordered)

**1. ruby** — Build Ruby 4.0.2 from source via autotools plugin
- Source: `https://cache.ruby-lang.org/pub/ruby/4.0/ruby-4.0.2.tar.gz`
- `--prefix=/usr --disable-install-doc --enable-shared`
- Build-packages: gcc, g++, make, autoconf, libssl-dev, libreadline-dev, zlib1g-dev, libffi-dev, libyaml-dev, libgmp-dev, rustc, cargo (for YJIT)
- Stage-packages: runtime libs (libssl3t64, libreadline8t64, zlib1g, libffi8, libyaml-0-2, libgmp10)

**2. libsodium** — Stage `libsodium23` from Ubuntu archive (for rbnacl FFI)

**3. gems** (after: ruby, libsodium) — override-build that:
- Sets `PATH` to staged Ruby, `GEM_HOME` to install dir
- `gem install omq-cli rbnacl zstd-ruby msgpack --no-document`
- Prunes gem cache, test/, spec/ dirs in prime

**4. wrappers** — dump plugin copies wrapper scripts to `bin/`

## Wrapper Script

Sets `GEM_PATH` and `LD_LIBRARY_PATH`, then exec the gem-installed binstub:

```bash
#!/bin/bash
export GEM_PATH="$SNAP/usr/lib/gems"
export LD_LIBRARY_PATH="$SNAP/usr/lib/${SNAP_ARCH_TRIPLET}:${LD_LIBRARY_PATH}"
exec "$SNAP/usr/bin/ruby" "$SNAP/usr/lib/gems/bin/omq" "$@"
```

The gem-installed binstub activates gems via RubyGems (not Bundler) — fast activation, no 300ms Bundler overhead.

## Key Design Decisions

1. **Install from RubyGems** (not local source) — simpler build, gems are published
2. **GEM_PATH + binstubs** — RubyGems handles gem activation and load paths, native `.so` files are found automatically
3. **YJIT included** — rustc/cargo as build-packages; meaningful perf benefit for omq
4. **`home` interface** — lets `omq -r./my_lib` access files in `$HOME`
5. **rbnacl for CURVE** — audited libsodium backend; snap bundles libsodium so no extra deps
6. **nuckle not included** — rbnacl is the right choice for a system package (audited crypto)

## Confinement Notes

- IPC sockets (`ipc://`) only work under `$HOME` with strict confinement
- `/tmp` paths need the `home` plug connected or use `$SNAP_USER_COMMON`
- TCP and inproc transports work without restrictions

## Verification

1. `snapcraft` — builds in LXD container
2. `sudo snap install omq_*.snap --dangerous`
3. `omq --version`
4. `echo hello | omq push -c tcp://127.0.0.1:5555` / `omq pull -b tcp://127.0.0.1:5555` — verify networking
5. `omq rep -b tcp://:5555 --echo --curve-server` — verify CURVE (tests rbnacl + libsodium linkage)
6. `omq --help` — verify all features listed (compression, CURVE, etc.)
