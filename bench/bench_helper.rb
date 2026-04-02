# frozen_string_literal: true

# Shared scaffolding for per-pattern throughput benchmarks.
#
# Usage:
#   require_relative '../bench_helper'
#   BenchHelper.run("PUSH/PULL", readme_marker: "push-pull-plots") do |transport, ep, peers, payload, n|
#     # Set up sockets, measure, return { mbps:, msgs_s: }
#   end

$VERBOSE = nil
$stdout.sync = true

require_relative '../lib/omq'
require 'async'
require 'console'
Console.logger = Console::Logger.new(Console::Output::Null.new)

module BenchHelper
  N     = 100_000
  SIZES = [64, 256, 1024, 4096, 65_536]

  module_function

  def run(label, dir:, peer_counts: [1, 3], &block)
    jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "+YJIT" : "no JIT"
    puts "#{label} | OMQ #{OMQ::VERSION} | Ruby #{RUBY_VERSION} (#{jit})"
    puts "#{N} messages per run"
    puts

    results = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
    seq     = 0

    %w[inproc ipc tcp].each do |transport|
      peer_counts.each do |peers|
        puts "--- #{transport} (#{peers} peer#{'s' if peers > 1}) ---"
        SIZES.each do |size|
          seq += 1
          Async do
            OMQ::Transport::Inproc.reset! if transport == "inproc"
            ep = endpoint(transport, seq)
            r  = block.call(transport, ep, peers, "x" * size, N)
            results[transport][peers] << { size: size, **r }
          end
        end
        puts
      end
    end

    require_relative 'plot'
    plot_text = OMQ::Bench::Plot.render_all(results, sizes: SIZES)
    write_readme(dir, label, plot_text)
  end

  def endpoint(transport, seq)
    case transport
    when "inproc" then "inproc://bench-#{seq}"
    when "ipc"    then "ipc://@omq-bench-#{seq}"
    when "tcp"    then "tcp://127.0.0.1:0"
    end
  end

  def measure(receiver, senders, payload, n)
    per_sender = n / senders.size

    # Warm up
    100.times { senders.first << payload; receiver.receive }

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    tasks = senders.map do |s|
      Async { per_sender.times { s << payload } }
    end

    (per_sender * senders.size).times { receiver.receive }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    tasks.each(&:wait)

    report(payload.bytesize, n, elapsed)
  end

  def measure_roundtrip(requester, responder_task, payload, n)
    # Warm up
    100.times { requester << payload; requester.receive }

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    n.times { requester << payload; requester.receive }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    report(payload.bytesize, n, elapsed)
  end

  def report(msg_size, n, elapsed)
    mbps   = n * msg_size / elapsed / 1_000_000.0
    msgs_s = n / elapsed
    printf "  %6s  %8.1f MB/s  %8.0f msg/s  (%.2fs)\n",
           "#{msg_size}B", mbps, msgs_s, elapsed
    { mbps: mbps, msgs_s: msgs_s }
  end

  def wait_connected(*sockets)
    sockets.flatten.each { |s| s.peer_connected.wait }
  end

  def write_readme(dir, label, plot_text)
    jit     = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "+YJIT" : "no JIT"
    readme  = "# #{label}\n\n"
    readme << "OMQ #{OMQ::VERSION} | Ruby #{RUBY_VERSION} (#{jit}) | #{Time.now.strftime('%Y-%m-%d')}\n\n"
    readme << "```\n#{plot_text}```\n"

    path = File.join(dir, 'README.md')
    File.write(path, readme)
    puts "(wrote #{path})"
  end
end
