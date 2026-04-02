# frozen_string_literal: true

# PUB/SUB fan-out throughput.
# PUB sends N messages, each SUB receives all N.
# msgs/s = publish rate.

require_relative "../bench_helper"

BenchHelper.run("PUB/SUB", dir: __dir__) do |transport, ep, peers, payload, n|
  pub = OMQ::PUB.bind(ep)
  ep  = "tcp://127.0.0.1:#{pub.last_tcp_port}" if transport == "tcp"

  subs = peers.times.map { OMQ::SUB.connect(ep, subscribe: "") }
  BenchHelper.wait_connected(subs) unless transport == "inproc"

  # Warm up (ensure subscriptions are active)
  100.times do
    pub << payload
    subs.each(&:receive)
  end

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  sender = Async { n.times { pub << payload } }

  # Each sub must receive all N messages
  receivers = subs.map do |sub|
    Async { n.times { sub.receive } }
  end
  receivers.each(&:wait)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  sender.wait

  begin
    BenchHelper.report(payload.bytesize, n, elapsed)
  ensure
    subs.each(&:close)
    pub.close
  end
end
