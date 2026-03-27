# frozen_string_literal: true

module OMQ
  class CHANNEL < Socket
    include ZMTP::Readable
    include ZMTP::Writable
    include ZMTP::SingleFrame

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:CHANNEL, linger: linger)
      _attach(endpoints, default: :connect)
    end
  end
end
