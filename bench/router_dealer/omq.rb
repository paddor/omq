# frozen_string_literal: true

# ROUTER/DEALER throughput: DEALER sends, ROUTER receives.

require_relative "../bench_helper"

BenchHelper.run("ROUTER/DEALER", dir: __dir__) do |transport, ep, peers, payload, n|
  router = OMQ::ROUTER.bind(ep)
  ep     = "tcp://127.0.0.1:#{router.last_tcp_port}" if transport == "tcp"

  dealers = peers.times.map do |i|
    d = OMQ::DEALER.new
    d.identity = "d#{i}"
    d.connect(ep)
    d
  end
  BenchHelper.wait_connected(dealers) unless transport == "inproc"

  per_dealer = n / dealers.size

  # Warm up
  100.times { dealers.first << payload; router.receive }

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  tasks = dealers.map do |d|
    Async { per_dealer.times { d << payload } }
  end

  (per_dealer * dealers.size).times { router.receive }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  tasks.each(&:wait)

  begin
    BenchHelper.report(payload.bytesize, n, elapsed)
  ensure
    dealers.each(&:close)
    router.close
  end
end
