# frozen_string_literal: true

require_relative "../test_helper"

describe "DEALER/ROUTER over inproc" do
  before { OMQ::ZMTP::Transport::Inproc.reset! }

  it "routes messages by identity" do
    Async do
      router = OMQ::ROUTER.bind("inproc://dealerrouter-1")
      dealer = OMQ::DEALER.new
      dealer.options.identity = "dealer-1"
      dealer.connect("inproc://dealerrouter-1")

      dealer.send("hello from dealer")
      msg = router.receive
      # ROUTER prepends identity frame
      assert_equal "dealer-1", msg[0]
      assert_equal "hello from dealer", msg[1]

      # Route reply back using identity
      router.send_to(msg[0], "hello back")
      reply = dealer.receive
      # DEALER sees the empty delimiter + message
      assert_equal ["", "hello back"], reply
    ensure
      dealer&.close
      router&.close
    end
  end
end
