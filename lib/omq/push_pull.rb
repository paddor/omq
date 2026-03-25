# frozen_string_literal: true

module OMQ
  class PUSH < Socket
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:PUSH, linger: linger)
      _attach(endpoints, default: :connect)
    end
  end

  class PULL < Socket
    include ZMTP::Readable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:PULL, linger: linger)
      _attach(endpoints, default: :bind)
    end
  end
end
