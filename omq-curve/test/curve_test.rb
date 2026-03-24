# frozen_string_literal: true

require_relative "test_helper"
require "socket"

describe "CURVE encryption" do
  # Generate keypairs for server and client
  def generate_keypair
    secret = RbNaCl::PrivateKey.generate
    [secret.public_key.to_s, secret.to_s]
  end

  def make_socketpair
    UNIXSocket.pair.map { |s| OMQ::ZMTP::Transport::TCP::SocketIO.new(s) }
  end

  describe "Connection-level handshake" do
    it "completes CURVE handshake between client and server" do
      server_pub, server_sec = generate_keypair
      client_pub, client_sec = generate_keypair

      Async do
        client_io, server_io = make_socketpair

        server_mechanism = OMQ::ZMTP::Mechanism::Curve.new(
          server_key: server_pub,
          public_key: server_pub,
          secret_key: server_sec,
          as_server:  true,
        )

        client_mechanism = OMQ::ZMTP::Mechanism::Curve.new(
          server_key: server_pub,
          public_key: client_pub,
          secret_key: client_sec,
          as_server:  false,
        )

        server = OMQ::ZMTP::Connection.new(
          server_io,
          socket_type: "REP",
          as_server:   true,
          mechanism:   server_mechanism,
        )

        client = OMQ::ZMTP::Connection.new(
          client_io,
          socket_type: "REQ",
          as_server:   false,
          mechanism:   client_mechanism,
        )

        server_task = Async { server.handshake! }
        client_task = Async { client.handshake! }

        client_task.wait
        server_task.wait

        assert_equal "REP", client.peer_socket_type
        assert_equal "REQ", server.peer_socket_type
      ensure
        client_io&.close
        server_io&.close
      end
    end

    it "sends and receives encrypted messages" do
      server_pub, server_sec = generate_keypair
      client_pub, client_sec = generate_keypair

      Async do
        client_io, server_io = make_socketpair

        server_mechanism = OMQ::ZMTP::Mechanism::Curve.new(
          server_key: server_pub,
          public_key: server_pub,
          secret_key: server_sec,
          as_server:  true,
        )

        client_mechanism = OMQ::ZMTP::Mechanism::Curve.new(
          server_key: server_pub,
          public_key: client_pub,
          secret_key: client_sec,
          as_server:  false,
        )

        server = OMQ::ZMTP::Connection.new(
          server_io,
          socket_type: "PAIR",
          as_server:   true,
          mechanism:   server_mechanism,
        )

        client = OMQ::ZMTP::Connection.new(
          client_io,
          socket_type: "PAIR",
          as_server:   false,
          mechanism:   client_mechanism,
        )

        [Async { server.handshake! }, Async { client.handshake! }].each(&:wait)

        # Send from client to server
        Async { client.send_message(["hello", "world"]) }
        msg = nil
        Async { msg = server.receive_message }.wait

        assert_equal ["hello", "world"], msg

        # Send from server to client
        Async { server.send_message(["reply"]) }
        msg2 = nil
        Async { msg2 = client.receive_message }.wait

        assert_equal ["reply"], msg2
      ensure
        client_io&.close
        server_io&.close
      end
    end

    it "rejects wrong server key" do
      server_pub, server_sec = generate_keypair
      client_pub, client_sec = generate_keypair

      Async do |task|
        client_io, server_io = make_socketpair

        server_mechanism = OMQ::ZMTP::Mechanism::Curve.new(
          server_key: server_pub,
          public_key: server_pub,
          secret_key: server_sec,
          as_server:  true,
        )

        # Client uses wrong server key
        wrong_pub, _ = generate_keypair
        client_mechanism = OMQ::ZMTP::Mechanism::Curve.new(
          server_key: wrong_pub,
          public_key: client_pub,
          secret_key: client_sec,
          as_server:  false,
        )

        server = OMQ::ZMTP::Connection.new(
          server_io,
          socket_type: "REP",
          as_server:   true,
          mechanism:   server_mechanism,
        )

        client = OMQ::ZMTP::Connection.new(
          client_io,
          socket_type: "REQ",
          as_server:   false,
          mechanism:   client_mechanism,
        )

        errors = []
        server_task = Async do
          server.handshake!
        rescue OMQ::ZMTP::ProtocolError, EOFError, RbNaCl::CryptoError => e
          errors << e
          server_io.close rescue nil
        end

        client_task = Async do
          client.handshake!
        rescue OMQ::ZMTP::ProtocolError, EOFError, RbNaCl::CryptoError => e
          errors << e
          client_io.close rescue nil
        end

        task.with_timeout(5) do
          server_task.wait
          client_task.wait
        end

        refute_empty errors, "expected handshake to fail with wrong server key"
      ensure
        client_io&.close rescue nil
        server_io&.close rescue nil
      end
    end
  end

  describe "Socket-level with options" do
    it "works end-to-end over tcp with REQ/REP" do
      server_pub, server_sec = generate_keypair
      client_pub, client_sec = generate_keypair

      Async do |task|
        rep = OMQ::REP.new
        rep.mechanism       = :curve
        rep.curve_server    = true
        rep.curve_public_key = server_pub
        rep.curve_secret_key = server_sec
        rep.curve_server_key = server_pub
        rep.bind("tcp://127.0.0.1:0")

        port = rep.last_tcp_port

        req = OMQ::REQ.new
        req.mechanism       = :curve
        req.curve_server    = false
        req.curve_public_key = client_pub
        req.curve_secret_key = client_sec
        req.curve_server_key = server_pub
        req.connect("tcp://127.0.0.1:#{port}")

        task.async do
          msg = rep.receive
          rep << msg.map(&:upcase)
        end

        req << "hello"
        reply = req.receive
        assert_equal ["HELLO"], reply
      ensure
        req&.close
        rep&.close
      end
    end

    it "works end-to-end over ipc with PUB/SUB" do
      server_pub, server_sec = generate_keypair
      client_pub, client_sec = generate_keypair
      addr = "ipc:///tmp/omq_curve_test_#{$$}.sock"

      Async do |task|
        pub = OMQ::PUB.new
        pub.mechanism       = :curve
        pub.curve_server    = true
        pub.curve_public_key = server_pub
        pub.curve_secret_key = server_sec
        pub.curve_server_key = server_pub
        pub.bind(addr)

        sub = OMQ::SUB.new
        sub.mechanism       = :curve
        sub.curve_server    = false
        sub.curve_public_key = client_pub
        sub.curve_secret_key = client_sec
        sub.curve_server_key = server_pub
        sub.connect(addr)
        sub.subscribe("")

        # Allow subscription to propagate
        sleep 0.1

        task.async { pub << "encrypted news" }
        msg = sub.receive
        assert_equal ["encrypted news"], msg
      ensure
        pub&.close
        sub&.close
      end
    end
  end
end
