# frozen_string_literal: true

require_relative "../test_helper"

describe "ROUTER router_mandatory option" do
  before { OMQ::ZMTP::Transport::Inproc.reset! }

  it "silently drops messages to unknown identity by default" do
    Async do
      router = OMQ::ROUTER.bind("inproc://rm-1")
      dealer = OMQ::DEALER.new
      dealer.identity = "known"
      dealer.connect("inproc://rm-1")

      # Send to unknown identity — should not raise
      router.send(["unknown-peer", "", "hello"])

      # Known identity still works
      router.send_to("known", "hi")
      msg = dealer.receive
      assert_includes msg, "hi"
    ensure
      dealer&.close
      router&.close
    end
  end

  it "raises SocketError synchronously with router_mandatory" do
    Async do
      router = OMQ::ROUTER.bind("inproc://rm-2")
      router.router_mandatory = true

      assert_raises(SocketError) do
        router.send(["nonexistent", "", "hello"])
      end

      # Router still works after the error
      dealer = OMQ::DEALER.new
      dealer.identity = "real"
      dealer.connect("inproc://rm-2")

      router.send_to("real", "works")
      msg = dealer.receive
      assert_includes msg, "works"
    ensure
      dealer&.close
      router&.close
    end
  end
end

describe "XPUB/SUB over TCP" do
  it "receives subscription notifications over TCP" do
    Async do
      xpub = OMQ::XPUB.bind("tcp://127.0.0.1:0")
      port = xpub.last_tcp_port

      sub = OMQ::SUB.new(nil, linger: 0, prefix: nil)
      sub.connect("tcp://127.0.0.1:#{port}")
      sub.subscribe("topic.")

      msg = xpub.receive
      assert_equal 1, msg.size
      assert_equal "\x01topic.".b, msg.first
    ensure
      sub&.close
      xpub&.close
    end
  end

  it "delivers filtered messages over TCP" do
    Async do
      xpub = OMQ::XPUB.bind("tcp://127.0.0.1:0")
      port = xpub.last_tcp_port

      sub = OMQ::SUB.connect("tcp://127.0.0.1:#{port}", prefix: "news.")

      # Consume subscription notification
      xpub.receive

      xpub.send("news.headline")
      msg = sub.receive
      assert_equal ["news.headline"], msg
    ensure
      sub&.close
      xpub&.close
    end
  end
end

describe "max_message_size with multi-frame" do
  it "rejects when one frame in a multi-frame message exceeds limit" do
    Async do
      rep = OMQ::REP.new(nil, linger: 0)
      rep.max_message_size = 50
      rep.bind("tcp://127.0.0.1:0")
      port = rep.last_tcp_port

      req = OMQ::REQ.new(nil, linger: 0)
      req.connect("tcp://127.0.0.1:#{port}")

      # First frame ok, second exceeds limit
      req.send(["small", "x" * 100])

      rep.read_timeout = 0.1
      assert_raises(IO::TimeoutError) { rep.receive }
    ensure
      req&.close
      rep&.close
    end
  end
end

describe "Socket#inspect" do
  before { OMQ::ZMTP::Transport::Inproc.reset! }

  it "includes class name and last_endpoint" do
    Async do
      rep = OMQ::REP.bind("inproc://inspect-test")
      s = rep.inspect
      assert_match(/OMQ::REP/, s)
      assert_match(/inproc:\/\/inspect-test/, s)
    ensure
      rep&.close
    end
  end

  it "shows nil endpoint before bind/connect" do
    rep = OMQ::REP.new
    assert_match(/nil/, rep.inspect)
  ensure
    rep&.close
  end
end

describe "ØMQ alias" do
  it "is the same as OMQ" do
    assert_equal OMQ, ØMQ
    assert_equal OMQ::REQ, ØMQ::REQ
    assert_equal OMQ::PUB, ØMQ::PUB
  end
end

describe "Empty and binary messages" do
  before { OMQ::ZMTP::Transport::Inproc.reset! }

  it "handles empty string message" do
    Async do
      pull = OMQ::PULL.bind("inproc://empty-msg")
      push = OMQ::PUSH.connect("inproc://empty-msg")

      push.send("")
      msg = pull.receive
      assert_equal [""], msg
    ensure
      push&.close
      pull&.close
    end
  end

  it "handles binary data with all 256 byte values" do
    Async do
      pull = OMQ::PULL.bind("inproc://binary-msg")
      push = OMQ::PUSH.connect("inproc://binary-msg")

      binary = (0..255).map(&:chr).join.b
      push.send(binary)
      msg = pull.receive
      assert_equal [binary], msg
    ensure
      push&.close
      pull&.close
    end
  end
end

describe "Linger drains over TCP" do
  it "actually delivers all messages before close completes" do
    Async do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.last_tcp_port

      push = OMQ::PUSH.new(nil, linger: 2)
      push.connect("tcp://127.0.0.1:#{port}")
      sleep 0.1

      20.times { |i| push.send("drain-#{i}") }
      push.close

      received = []
      20.times do
        pull.recv_timeout = 1
        received << pull.receive.first
      end

      assert_equal 20, received.size
      assert_equal "drain-0", received.first
      assert_equal "drain-19", received.last
    ensure
      pull&.close
    end
  end
end

describe "Timeouts on various socket types" do
  before { OMQ::ZMTP::Transport::Inproc.reset! }

  it "recv_timeout works on SUB" do
    Async do
      pub = OMQ::PUB.bind("inproc://timeout-sub")
      sub = OMQ::SUB.connect("inproc://timeout-sub", prefix: "")
      sub.recv_timeout = 0.05

      assert_raises(IO::TimeoutError) { sub.receive }
    ensure
      sub&.close
      pub&.close
    end
  end

  it "recv_timeout works on PAIR" do
    Async do
      a = OMQ::PAIR.bind("inproc://timeout-pair")
      b = OMQ::PAIR.connect("inproc://timeout-pair")
      b.recv_timeout = 0.05

      assert_raises(IO::TimeoutError) { b.receive }
    ensure
      a&.close
      b&.close
    end
  end

  it "recv_timeout works on REP" do
    Async do
      rep = OMQ::REP.bind("inproc://timeout-rep")
      rep.recv_timeout = 0.05

      assert_raises(IO::TimeoutError) { rep.receive }
    ensure
      rep&.close
    end
  end

  it "recv_timeout works on DEALER" do
    Async do
      router = OMQ::ROUTER.bind("inproc://timeout-dealer")
      dealer = OMQ::DEALER.connect("inproc://timeout-dealer")
      dealer.recv_timeout = 0.05

      assert_raises(IO::TimeoutError) { dealer.receive }
    ensure
      dealer&.close
      router&.close
    end
  end
end
