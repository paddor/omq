# frozen_string_literal: true

module OMQ
  module ZMTP
    # Shared helpers for security mechanism implementations.
    #
    module Mechanism
      private

      def read_exact(io, n)
        data = "".b
        while data.bytesize < n
          chunk = io.read(n - data.bytesize)
          raise EOFError, "connection closed" if chunk.nil? || chunk.empty?
          data << chunk
        end
        data
      end
    end
  end
end
