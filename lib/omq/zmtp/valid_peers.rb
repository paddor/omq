# frozen_string_literal: true

module OMQ
  module ZMTP
    # Valid socket type peer combinations per ZMTP spec.
    #
    VALID_PEERS = {
      PAIR:   %i[PAIR].freeze,
      REQ:    %i[REP ROUTER].freeze,
      REP:    %i[REQ DEALER].freeze,
      DEALER: %i[REP DEALER ROUTER].freeze,
      ROUTER: %i[REQ DEALER ROUTER].freeze,
      PUB:    %i[SUB XSUB].freeze,
      SUB:    %i[PUB XPUB].freeze,
      XPUB:   %i[SUB XSUB].freeze,
      XSUB:   %i[PUB XPUB].freeze,
      PUSH:   %i[PULL].freeze,
      PULL:   %i[PUSH].freeze,
    }.freeze
  end
end
