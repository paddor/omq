# frozen_string_literal: true

module OMQ
  module Routing
    # PULL socket routing: fair-queue receive from PUSH peers.
    #
    class Pull
      # @param engine [Engine]
      #
      def initialize(engine)
        @engine     = engine
        @recv_queue = FairQueue.new
        @tasks      = []
      end

      # @return [FairQueue]
      #
      attr_reader :recv_queue

      # @param connection [Connection]
      #
      def connection_added(connection)
        conn_q    = Routing.build_queue(@engine.options.recv_hwm, :block)
        signaling = SignalingQueue.new(conn_q, @recv_queue)
        @recv_queue.add_queue(connection, conn_q)
        task = @engine.start_recv_pump(connection, signaling)
        @tasks << task if task
      end

      # @param connection [Connection]
      #
      def connection_removed(connection)
        @recv_queue.remove_queue(connection)
        # recv pump stops on EOFError
      end

      # PULL is read-only.
      #
      def enqueue(_parts)
        raise "PULL sockets cannot send"
      end

      #
      def stop
        @tasks.each(&:stop)
        @tasks.clear
      end
    end
  end
end
