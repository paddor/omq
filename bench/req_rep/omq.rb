# frozen_string_literal: true

# REQ/REP synchronous roundtrip throughput.

require_relative "../bench_helper"

BenchHelper.run("REQ/REP", dir: __dir__) do |transport, ep, peers, payload, n|
  Async do |task|
    rep = OMQ::REP.bind(ep)
    ep  = "tcp://127.0.0.1:#{rep.last_tcp_port}" if transport == "tcp"
    req = OMQ::REQ.connect(ep)

    responder = task.async do
      loop do
        msg = rep.receive
        rep << msg
      end
    end

    begin
      BenchHelper.measure_roundtrip(req, responder, payload, n)
    ensure
      responder.stop
      req.close
      rep.close
    end
  end.wait
end
