# frozen_string_literal: true

require_relative "../../lib/omq"
require "async"

endpoint = ARGV[0] || "tcp://localhost:5557"

Async do
  push = OMQ::PUSH.new(endpoint)
  puts "Ventilator on #{endpoint.delete_prefix(">")} — type tasks, one per line"

  loop do
    print "> "
    input = $stdin.gets&.chomp
    break if input.nil? || input.empty?

    push << input
    puts "  sent"
  end
ensure
  push&.close
end
