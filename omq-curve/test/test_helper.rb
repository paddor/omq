# frozen_string_literal: true

$VERBOSE = nil # suppress IO::Buffer experimental warnings

require "minitest/autorun"
require "omq-curve"
require "async"

require "console"
Console.logger = Console::Logger.new(Console::Output::Null.new)
