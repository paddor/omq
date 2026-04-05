# frozen_string_literal: true

module OMQ
  module Routing
    # REQ socket routing: round-robin send with strict send/recv alternation.
    #
    # REQ prepends an empty delimiter frame on send and strips it on receive.
    #
    class Req
      include RoundRobin

      # @param engine [Engine]
      #
      def initialize(engine)
        @engine          = engine
        @recv_queue      = FairQueue.new
        @tasks           = []
        @state           = :ready        # :ready or :waiting_reply
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
        task = @engine.start_recv_pump(connection, signaling) do |msg|
          @state = :ready
          msg.first&.empty? ? msg[1..] : msg
        end
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
        raise SocketError, "REQ socket expects send/recv/send/recv order" unless @state == :ready
        @state = :waiting_reply
        enqueue_round_robin(parts)
      end

      #
      def stop
        @tasks.each(&:stop)
        @tasks.clear
      end

      private

      # REQ prepends empty delimiter frame on the wire.
      #
      def transform_send(parts) = [EMPTY_BINARY, *parts]
    end
  end
end
