#!/bin/sh
#
# omqcat pipeline benchmark
#
# Topology:
#
#   ┌──────────┐     ┌────────┐     ┌──────┐
#   │ producer │─TCP─│ worker │─TCP─│ sink │
#   │ PUSH     │     │ ×4     │     │ PULL │
#   └──────────┘     └────────┘     └──────┘
#
# Producer sends N integers (cycling 1..28).
# Each worker computes fib(n) and forwards the result.
# Workers exit via --timeout when idle — no sentinels needed.
# Sink exits via --transient when all workers disconnect.
#
# Usage: sh bench/omqcat/pipeline.sh [count]
#
set -u

OMQCAT="ruby --yjit -Ilib exe/omqcat"
BENCH_DIR=$(cd "$(dirname "$0")" && pwd)
N=${1:-1000}
WORKERS=4
WORK_PORT=$((19000 + $$ % 500))
SINK_PORT=$((WORK_PORT + 1))

echo "omqcat pipeline benchmark — $N messages, $WORKERS workers, fib(1..28)"
echo

# ── Sink: PULL results ────────────────────────────────────────────

$OMQCAT pull --bind tcp://:$SINK_PORT \
  --transient --quiet \
  > /dev/null 2>/dev/null &
SINK_PID=$!

# ── Workers: PULL → fib → PUSH ───────────────────────────────────

WORKER_PIDS=""
i=0
while [ $i -lt $WORKERS ]; do
  $OMQCAT pull --connect tcp://localhost:$WORK_PORT --timeout 1 \
    -r"$BENCH_DIR/fib.rb" \
    -e '[fib(Integer($F.first)).to_s]' \
    2>/dev/null \
  | $OMQCAT push --connect tcp://localhost:$SINK_PORT --linger 0.5 \
    2>/dev/null &
  WORKER_PIDS="$WORKER_PIDS $!"
  i=$((i + 1))
done

# ── Producer: bind early, then feed work after workers connect ────

START=$(ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')

# Shell sleep gives workers time to boot before we even start
# the producer. The linger on the producer keeps the listener
# alive until all queued messages are delivered.
sleep 1
ruby --yjit -e "
ints = (1..28).cycle
$N.times { puts ints.next }
" | $OMQCAT push --bind tcp://:$WORK_PORT --linger 2 2>/dev/null

# ── Wait for pipeline to drain ────────────────────────────────────

wait $SINK_PID 2>/dev/null

END=$(ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')

ELAPSED=$(ruby -e "puts ($END - $START).round(3)")
RATE=$(ruby -e "puts ($N.to_f / ($END - $START)).round(1)")

echo "  $WORKERS workers: $RATE msg/s ($N messages in ${ELAPSED}s)"

# Clean up
for pid in $WORKER_PIDS; do
  kill $pid 2>/dev/null
done
wait 2>/dev/null
