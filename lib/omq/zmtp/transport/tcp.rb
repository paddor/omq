# frozen_string_literal: true

require "socket"
require "uri"
require "io/stream"

module OMQ
  module ZMTP
    module Transport
      # TCP transport using Ruby sockets with Async.
      #
      module TCP
        class << self
          # Binds a TCP server.
          #
          # @param endpoint [String] e.g. "tcp://127.0.0.1:5555" or "tcp://*:0"
          # @param engine [Engine]
          # @return [Listener]
          #
          def bind(endpoint, engine)
            host, port = parse_endpoint(endpoint)
            host = "0.0.0.0" if host == "*"
            server = TCPServer.new(host, port)
            actual_port = server.local_address.ip_port
            host_part   = host.include?(":") ? "[#{host}]" : host
            resolved    = "tcp://#{host_part}:#{actual_port}"

            accept_task = Reactor.spawn_pump(annotation: "tcp accept #{resolved}") do
              loop do
                client = server.accept
                Async::Task.current.defer_stop do
                  engine.handle_accepted(IO::Stream::Buffered.wrap(client), endpoint: resolved)
                end
              end
            rescue IOError
              # server closed
            end

            Listener.new(resolved, server, accept_task, actual_port)
          end

          # Connects to a TCP endpoint.
          #
          # @param endpoint [String] e.g. "tcp://127.0.0.1:5555"
          # @param engine [Engine]
          # @return [void]
          #
          def connect(endpoint, engine)
            host, port = parse_endpoint(endpoint)
            sock = TCPSocket.new(host, port)
            engine.handle_connected(IO::Stream::Buffered.wrap(sock), endpoint: endpoint)
          end

          private

          # Parses a TCP endpoint URI into host and port.
          #
          # @param endpoint [String]
          # @return [Array(String, Integer)]
          #
          def parse_endpoint(endpoint)
            uri = URI.parse(endpoint)
            [uri.hostname, uri.port]
          end
        end

        # A bound TCP listener.
        #
        class Listener
          # @return [String] resolved endpoint with actual port
          #
          attr_reader :endpoint

          # @return [Integer] bound port
          #
          attr_reader :port


          # @param endpoint [String] resolved endpoint URI
          # @param server [TCPServer]
          # @param accept_task [#stop] the accept loop handle
          # @param port [Integer] bound port number
          #
          def initialize(endpoint, server, accept_task, port)
            @endpoint    = endpoint
            @server      = server
            @accept_task = accept_task
            @port        = port
          end


          # Stops the listener.
          #
          def stop
            @accept_task.stop
            @server.close rescue nil
          end
        end
      end
    end
  end
end
