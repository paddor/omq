# frozen_string_literal: true

require "async"
require "async/queue"
require "async/limited_queue"

module OMQ
  # Routing strategies for each ZMQ socket type.
  #
  # Each strategy manages how messages flow between connections and
  # the socket's send/recv queues.
  #
  module Routing
    # Shared frozen empty binary string to avoid repeated allocations.
    EMPTY_BINARY = "".b.freeze

    # Drains all available messages from +queue+ into +batch+ without
    # blocking. Call after the initial blocking dequeue.
    #
    # No cap is needed: IO::Stream auto-flushes at 64 KB, so the
    # write buffer hits the wire naturally under sustained load.
    # The explicit flush after the batch pushes out the remainder.
    #
    # @param queue [Async::LimitedQueue]
    # @param batch [Array]
    # @return [void]
    #
    def self.drain_send_queue(queue, batch)
      loop do
        msg = queue.dequeue(timeout: 0)
        break unless msg
        batch << msg
      end
    end

    # Returns the routing strategy class for a socket type.
    #
    # @param socket_type [Symbol] e.g. :PAIR, :REQ
    # @return [Class]
    #
    def self.for(socket_type)
      case socket_type
      when :PAIR   then Pair
      when :REQ    then Req
      when :REP    then Rep
      when :DEALER then Dealer
      when :ROUTER then Router
      when :PUB    then Pub
      when :SUB    then Sub
      when :XPUB   then XPub
      when :XSUB   then XSub
      when :PUSH    then Push
      when :PULL    then Pull
      when :CLIENT  then Client
      when :SERVER  then Server
      when :RADIO   then Radio
      when :DISH    then Dish
      when :SCATTER then Scatter
      when :GATHER  then Gather
      when :PEER    then Peer
      when :CHANNEL then Channel
      else raise ArgumentError, "unknown socket type: #{socket_type}"
      end
    end
  end
end
