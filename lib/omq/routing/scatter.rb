# frozen_string_literal: true

module OMQ
  module Routing
    # SCATTER socket routing: round-robin send to GATHER peers.
    #
    class Scatter
      include RoundRobin

      # @param engine [Engine]
      #
      def initialize(engine)
        @engine = engine
        @tasks  = []
        init_round_robin(engine)
      end


      # @return [Async::LimitedQueue]
      #
      attr_reader :send_queue


      # SCATTER is write-only.
      #
      def recv_queue
        raise "SCATTER sockets cannot receive"
      end


      # @param connection [Connection]
      #
      def connection_added(connection)
        @connections << connection
        signal_connection_available
        update_direct_pipe
        start_send_pump unless @send_pump_started
        start_reaper(connection)
      end


      # @param connection [Connection]
      #
      def connection_removed(connection)
        @connections.delete(connection)
        update_direct_pipe
      end


      # @param parts [Array<String>]
      #
      def enqueue(parts)
        enqueue_round_robin(parts)
      end


      # Stops all background tasks (send pump, reapers).
      #
      def stop
        @tasks.each(&:stop)
        @tasks.clear
      end

      private


      # Detects peer disconnection on write-only sockets by
      # blocking on a receive that only returns on disconnect.
      #
      # @param conn [Connection]
      #
      def start_reaper(conn)
        return if conn.is_a?(Transport::Inproc::DirectPipe)
        @tasks << @engine.spawn_pump_task(annotation: "reaper") do
          conn.receive_message
        rescue *CONNECTION_LOST
          @engine.connection_lost(conn)
        end
      end
    end
  end
end
