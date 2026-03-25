# frozen_string_literal: true

require_relative "../test_helper"

describe "PUSH/PULL over inproc" do
  before { OMQ::ZMTP::Transport::Inproc.reset! }

  it "sends and receives messages" do
    Async do
      pull = OMQ::PULL.bind("inproc://pushpull-1")
      push = OMQ::PUSH.connect("inproc://pushpull-1")

      push.send("hello")
      msg = pull.receive
      assert_equal ["hello"], msg
    ensure
      push&.close
      pull&.close
    end
  end

  it "round-robins across multiple PULL peers" do
    Async do
      pull1 = OMQ::PULL.bind("inproc://pushpull-rr-1")
      pull2 = OMQ::PULL.bind("inproc://pushpull-rr-2")

      push = OMQ::PUSH.new
      push.connect("inproc://pushpull-rr-1")
      push.connect("inproc://pushpull-rr-2")

      push.send("msg1")
      push.send("msg2")

      msg1 = pull1.receive
      msg2 = pull2.receive

      assert_equal ["msg1"], msg1
      assert_equal ["msg2"], msg2
    ensure
      push&.close
      pull1&.close
      pull2&.close
    end
  end
end
