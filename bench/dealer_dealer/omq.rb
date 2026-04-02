# frozen_string_literal: true

# DEALER/DEALER async bidirectional throughput.
# One DEALER binds, N DEALERs connect and send. Binder receives.

require_relative "../bench_helper"

BenchHelper.run("DEALER/DEALER", dir: __dir__) do |transport, ep, peers, payload, n|
  receiver = OMQ::DEALER.bind(ep)
  ep       = "tcp://127.0.0.1:#{receiver.last_tcp_port}" if transport == "tcp"

  senders = peers.times.map { OMQ::DEALER.connect(ep) }
  BenchHelper.wait_connected(senders) unless transport == "inproc"

  begin
    BenchHelper.measure(receiver, senders, payload, n)
  ensure
    senders.each(&:close)
    receiver.close
  end
end
