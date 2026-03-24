# frozen_string_literal: true

$VERBOSE = nil

require_relative '../lib/omq-curve'
require 'async'
require 'benchmark/ips'
require 'console'
Console.logger = Console::Logger.new(Console::Output::Null.new)

server_secret = RbNaCl::PrivateKey.generate
server_pub    = server_secret.public_key.to_s
server_sec    = server_secret.to_s
client_secret = RbNaCl::PrivateKey.generate
client_pub    = client_secret.public_key.to_s
client_sec    = client_secret.to_s

TRANSPORTS = {
  'ipc' => 'ipc:///tmp/omq_bench_curve_latency.sock',
  'tcp' => 'tcp://127.0.0.1:9100',
}

jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "+YJIT" : "no JIT"
puts "OMQ #{OMQ::VERSION} + CURVE | Ruby #{RUBY_VERSION} (#{jit})"
puts

payload = 'ping'

TRANSPORTS.each do |transport, addr|
  puts "--- #{transport} ---"

  Async do |task|
    rep = OMQ::REP.new
    rep.mechanism        = :curve
    rep.curve_server     = true
    rep.curve_public_key = server_pub
    rep.curve_secret_key = server_sec
    rep.bind(addr)

    req = OMQ::REQ.new
    req.mechanism        = :curve
    req.curve_server     = false
    req.curve_public_key = client_pub
    req.curve_secret_key = client_sec
    req.curve_server_key = server_pub
    req.connect(addr)

    responder = task.async do
      loop do
        msg = rep.receive
        rep << msg
      end
    end

    # Warm up
    100.times do
      req << payload
      req.receive
    end

    Benchmark.ips do |x|
      x.config(warmup: 1, time: 3)

      x.report('roundtrip') do
        req << payload
        req.receive
      end
    end

    responder.stop
  ensure
    req&.close
    rep&.close
  end

  puts
end
