# frozen_string_literal: true

module OMQ
  class XSUB < Socket
    include ZMTP::Readable
    include ZMTP::Writable

    # @param endpoints [String, nil]
    # @param linger [Integer]
    # @param prefix [String, nil] subscription prefix; +nil+ (default)
    #   means no subscription — send a subscribe frame explicitly.
    #
    def initialize(endpoints = nil, linger: 0, prefix: nil)
      _init_engine(:XSUB, linger: linger)
      _attach(endpoints, default: :connect)
      send("\x01#{prefix}".b) unless prefix.nil?
    end
  end
end
