# frozen_string_literal: true

require_relative "../test_helper"

describe "non-Async usage" do
  before { OMQ::Transport::Inproc.reset! }

  it "sends and receives without an Async block" do
    pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
    port = pull.last_tcp_port
    push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}")

    push << "hello"
    assert_equal ["hello"], pull.receive
  ensure
    push&.close
    pull&.close
  end
end
