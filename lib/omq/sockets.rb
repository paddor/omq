# frozen_string_literal: true

module OMQ
  class REQ < Socket
    include ZMTP::Readable
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:REQ, linger: linger)
      _attach(endpoints, default: :connect)
    end
  end

  class REP < Socket
    include ZMTP::Readable
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:REP, linger: linger)
      _attach(endpoints, default: :bind)
    end
  end

  class DEALER < Socket
    include ZMTP::Readable
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:DEALER, linger: linger)
      _attach(endpoints, default: :connect)
    end
  end

  class PUB < Socket
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:PUB, linger: linger)
      _attach(endpoints, default: :bind)
    end
  end

  class XPUB < Socket
    include ZMTP::Readable
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:XPUB, linger: linger)
      _attach(endpoints, default: :bind)
    end
  end

  class XSUB < Socket
    include ZMTP::Readable
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:XSUB, linger: linger)
      _attach(endpoints, default: :connect)
    end
  end

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

  class PAIR < Socket
    include ZMTP::Readable
    include ZMTP::Writable

    def initialize(endpoints = nil, linger: 0)
      _init_engine(:PAIR, linger: linger)
      _attach(endpoints, default: :connect)
    end
  end
end
