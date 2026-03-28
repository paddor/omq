# frozen_string_literal: true

require_relative "../test_helper"

describe "Error paths" do
  before { OMQ::ZMTP::Transport::Inproc.reset! }

  describe "bind to invalid transport" do
    it "raises ArgumentError" do
      push = OMQ::PUSH.new
      assert_raises(ArgumentError) do
        push.bind("udp://127.0.0.1:5555")
      end
    ensure
      push&.close
    end
  end

  describe "double close" do
    it "is idempotent on PUSH" do
      Async do
        push = OMQ::PUSH.new
        push.close
        push.close
      end
    end

    it "is idempotent on PULL" do
      Async do
        pull = OMQ::PULL.bind("inproc://err-dblclose")
        pull.close
        pull.close
      end
    end

    it "is idempotent on REP" do
      Async do
        rep = OMQ::REP.bind("inproc://err-dblclose-rep")
        rep.close
        rep.close
      end
    end

    it "is idempotent on PAIR" do
      Async do
        pair = OMQ::PAIR.bind("inproc://err-dblclose-pair")
        pair.close
        pair.close
      end
    end
  end
end
