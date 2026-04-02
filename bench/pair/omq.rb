# frozen_string_literal: true

# PAIR exclusive 1-to-1 throughput.

require_relative "../bench_helper"

BenchHelper.run("PAIR", dir: __dir__, peer_counts: [1]) do |transport, ep, _peers, payload, n|
  receiver = OMQ::PAIR.bind(ep)
  ep       = "tcp://127.0.0.1:#{receiver.last_tcp_port}" if transport == "tcp"

  sender = OMQ::PAIR.connect(ep)
  BenchHelper.wait_connected(sender) unless transport == "inproc"

  begin
    BenchHelper.measure(receiver, [sender], payload, n)
  ensure
    sender.close
    receiver.close
  end
end
