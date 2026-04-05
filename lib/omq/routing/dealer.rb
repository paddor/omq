# frozen_string_literal: true

module OMQ
  module Routing
    # DEALER socket routing: round-robin send, fair-queue receive.
    #
    # No envelope manipulation — messages pass through unchanged.
    #
    class Dealer
      include RoundRobin

      # @param engine [Engine]
      #
      def initialize(engine)
        @engine     = engine
        @recv_queue = FairQueue.new
        @tasks      = []
        init_round_robin(engine)
      end

      # @return [FairQueue]
      #
      attr_reader :recv_queue

      # @param connection [Connection]
      #
      def connection_added(connection)
        @connections << connection
        conn_q    = Routing.build_queue(@engine.options.recv_hwm, :block)
        signaling = SignalingQueue.new(conn_q, @recv_queue)
        @recv_queue.add_queue(connection, conn_q)
        task = @engine.start_recv_pump(connection, signaling)
        @tasks << task if task
        add_round_robin_send_connection(connection)
      end

      # @param connection [Connection]
      #
      def connection_removed(connection)
        @connections.delete(connection)
        @recv_queue.remove_queue(connection)
        remove_round_robin_send_connection(connection)
      end

      # @param parts [Array<String>]
      #
      def enqueue(parts)
        enqueue_round_robin(parts)
      end

      #
      def stop
        @tasks.each(&:stop)
        @tasks.clear
      end
    end
  end
end
