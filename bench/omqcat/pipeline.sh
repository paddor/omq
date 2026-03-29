#!/bin/sh
#
# omq pipeline benchmark
#
# Topology:
#
#   +----------+     +--------+     +------+
#   | producer |-TCP-| worker |-TCP-| sink |- awk sum
#   | PUSH     |     | x4     |     | PULL |
#   +----------+     +--------+     +------+
#
# Producer sends N integers (cycling 1..28).
# Each worker computes fib(n) and forwards the result.
# Workers exit via --timeout when idle — no sentinels needed.
# Sink exits via --transient when all workers disconnect.
#
# Usage: sh bench/omq/pipeline.sh [count]
#
set -u

OMQ="ruby --yjit -Ilib exe/omq"
BENCH_DIR=$(cd "$(dirname "$0")" && pwd)
N=${1:-1000}
WORKERS=4
WORK_PORT=$((19000 + $$ % 500))
SINK_PORT=$((WORK_PORT + 1))

echo "omq pipeline benchmark — $N messages, $WORKERS workers, fib(1..28)"
echo

# ── Sink: PULL results ────────────────────────────────────────────

$OMQ pull --bind tcp://:$SINK_PORT \
  --transient \
  2>/dev/null \
| awk '{ s += $1 } END { print s }' > "/tmp/omq_bench_sum_$$" &
SINK_PID=$!

# ── Workers: PULL → fib → PUSH ───────────────────────────────────

WORKER_PIDS=""
i=0
while [ $i -lt $WORKERS ]; do
  $OMQ pull --connect tcp://localhost:$WORK_PORT --timeout 1 \
    -r"$BENCH_DIR/fib.rb" \
    -e '[fib(Integer($F.first)).to_s]' \
    2>/dev/null \
  | $OMQ push --connect tcp://localhost:$SINK_PORT --linger 0.5 \
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
" | $OMQ push --bind tcp://:$WORK_PORT --linger 2 2>/dev/null

# ── Wait for pipeline to drain ────────────────────────────────────

wait $SINK_PID 2>/dev/null

END=$(ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')

ELAPSED=$(ruby -e "puts ($END - $START).round(3)")
RATE=$(ruby -e "puts ($N.to_f / ($END - $START)).round(1)")

SUM=$(cat "/tmp/omq_bench_sum_$$")
echo "  $WORKERS workers: $RATE msg/s ($N messages in ${ELAPSED}s, sum=$SUM)"

# Clean up
rm -f "/tmp/omq_bench_sum_$$"
for pid in $WORKER_PIDS; do
  kill $pid 2>/dev/null
done
wait 2>/dev/null
