# frozen_string_literal: true

# OMQ — pure Ruby ZeroMQ (ZMTP 3.1).
#
# Socket types live directly under OMQ:: for a clean API:
#   OMQ::PUSH, OMQ::PULL, OMQ::PUB, OMQ::SUB, etc.
#
# Protocol internals live under OMQ::ZMTP:: and are not part
# of the public API.
#

require_relative "omq/version"
require_relative "omq/zmtp"
require_relative "omq/socket"
require_relative "omq/req_rep"
require_relative "omq/router_dealer"
require_relative "omq/pub_sub"
require_relative "omq/push_pull"
require_relative "omq/pair"

# For the purists.
ØMQ = OMQ
