# frozen_string_literal: true

# Benchmark: 3-stage push→pull pipeline
#
# Compares: Async fibers (ipc) vs Ractors (tcp)
#
# Pipeline: producer → stage1 → stage2 → stage3 → collector
# Each stage forwards the message (measures pure transport overhead).
#
# Run separately (Ractors need their own process):
#   ruby --yjit bench/ractors_vs_async.rb async
#   ruby --yjit bench/ractors_vs_async.rb ractors

$VERBOSE = nil

require_relative "../lib/omq"
require "async"
require "benchmark/ips"
require "console"
Console.logger = Console::Logger.new(Console::Output::Null.new)

PAYLOAD = ("x" * 64).freeze

jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "+YJIT" : "no JIT"
puts "OMQ #{OMQ::VERSION} | Ruby #{RUBY_VERSION} (#{jit})"
puts "Pipeline: producer → 3 stages → collector (64 B payload)"
puts

case ARGV[0]
when "async"
  Async do |task|
    addrs = 4.times.map { |i| "ipc:///tmp/omq_bench_pipe_#{i}_#{$$}.sock" }

    stages = []
    3.times do |i|
      pull = OMQ::PULL.bind(addrs[i])
      push = OMQ::PUSH.connect(addrs[i + 1])
      stages << [pull, push]
      task.async { loop { push << pull.receive } }
    end

    producer  = OMQ::PUSH.connect(addrs[0])
    collector = OMQ::PULL.bind(addrs[3])

    200.times { producer << PAYLOAD; collector.receive }

    Benchmark.ips do |x|
      x.config(warmup: 2, time: 5)
      x.report("async (ipc)") { producer << PAYLOAD; collector.receive }
    end
  ensure
    producer&.close; collector&.close
    stages&.each { |p, s| p&.close; s&.close }
  end

when "ractors"
  base  = 17_100 + rand(900)
  ports = 4.times.map { |i| base + i }

  3.times.map do |i|
    Ractor.new(ports[i], ports[i + 1]) do |inp, outp|
      Console.logger = Console::Logger.new(Console::Output::Null.new)
      Async do
        pull = OMQ::PULL.bind("tcp://127.0.0.1:#{inp}")
        push = OMQ::PUSH.connect("tcp://127.0.0.1:#{outp}")
        loop { push << pull.receive }
      ensure
        pull&.close; push&.close
      end
    end
  end

  Async do
    collector = OMQ::PULL.bind("tcp://127.0.0.1:#{ports[3]}")
    producer  = OMQ::PUSH.connect("tcp://127.0.0.1:#{ports[0]}")
    sleep 0.5
    200.times { producer << PAYLOAD; collector.receive }

    Benchmark.ips do |x|
      x.config(warmup: 2, time: 5)
      x.report("ractors (tcp)") { producer << PAYLOAD; collector.receive }
    end
  ensure
    producer&.close; collector&.close
  end
  exit!

else
  abort "Usage: ruby --yjit #{$0} [async|ractors]"
end
