# frozen_string_literal: true

# PUSH/PULL sustained pipeline throughput.

require_relative "../bench_helper"

BenchHelper.run("PUSH/PULL", dir: __dir__) do |transport, ep, peers, payload, n|
  pull = OMQ::PULL.bind(ep)
  ep   = "tcp://127.0.0.1:#{pull.last_tcp_port}" if transport == "tcp"

  pushes = peers.times.map { OMQ::PUSH.connect(ep) }
  BenchHelper.wait_connected(pushes) unless transport == "inproc"

  begin
    BenchHelper.measure(pull, pushes, payload, n)
  ensure
    pushes.each(&:close)
    pull.close
  end
end
