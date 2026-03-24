# frozen_string_literal: true

module OMQ
  module ZMTP
    module Mechanism
      # CurveZMQ security mechanism (RFC 26).
      #
      # Provides Curve25519-XSalsa20-Poly1305 encryption and authentication
      # for ZMTP 3.1 connections using the RbNaCl gem.
      #
      # After the 4-step handshake (HELLO/WELCOME/INITIATE/READY), all
      # frames are encrypted as CurveZMQ MESSAGE commands using the
      # transient session keys.
      #
      # DoS resistance (per RFC 26):
      # - Anti-amplification: HELLO (200 bytes) > WELCOME (168 bytes)
      # - Server statelessness: after sending WELCOME the server forgets
      #   all per-connection state. On INITIATE, it recovers cn_public and
      #   sn_secret from the cookie (which precedes the encrypted box in
      #   cleartext). Only the socket-wide @cookie_key is needed.
      # - Cookie verification prevents replay of stale INITIATEs.
      #
      class Curve
        include Mechanism

        MECHANISM_NAME = "CURVE"

        # Nonce prefixes. Most are 16 bytes (prefix + 8-byte counter on wire).
        # WELCOME, COOKIE, and VOUCH use 8-byte prefixes with 16-byte random nonces.
        NONCE_PREFIX_HELLO     = "CurveZMQHELLO---"  # 16 + 8
        NONCE_PREFIX_WELCOME   = "WELCOME-"           #  8 + 16
        NONCE_PREFIX_INITIATE  = "CurveZMQINITIATE"  # 16 + 8
        NONCE_PREFIX_READY     = "CurveZMQREADY---"  # 16 + 8
        NONCE_PREFIX_MESSAGE_C = "CurveZMQMESSAGEC"  # 16 + 8, client → server
        NONCE_PREFIX_MESSAGE_S = "CurveZMQMESSAGES"  # 16 + 8, server → client
        NONCE_PREFIX_VOUCH     = "VOUCH---"           #  8 + 16
        NONCE_PREFIX_COOKIE    = "COOKIE--"           #  8 + 16

        # Crypto overhead: 16 bytes Poly1305 authenticator
        BOX_OVERHEAD = 16

        # @param public_key [String] our permanent public key (32 bytes)
        # @param secret_key [String] our permanent secret key (32 bytes)
        # @param as_server [Boolean] whether we are the CURVE server
        # @param server_key [String, nil] server's permanent public key (32 bytes, required for clients)
        # @param authenticator [#include?, #call, nil] client key authenticator (server only).
        #   Set/Array → checked via #include?. Proc/lambda → called with the 32-byte
        #   client public key, must return truthy to allow. nil → allow all.
        #
        def initialize(server_key: nil, public_key:, secret_key:, as_server: false, authenticator: nil)
          @permanent_public = RbNaCl::PublicKey.new(public_key.b)
          @permanent_secret = RbNaCl::PrivateKey.new(secret_key.b)
          @as_server        = as_server
          @authenticator    = authenticator

          if as_server
            # One cookie key per socket — enables server statelessness per-connection
            @cookie_key = RbNaCl::Random.random_bytes(32)
          else
            raise ArgumentError, "server_key is required for CURVE clients" unless server_key
            @server_public = RbNaCl::PublicKey.new(server_key.b)
          end

          # Session state (set during handshake)
          @session_box = nil  # RbNaCl::Box for MESSAGE encryption
          @send_nonce  = 0    # outgoing MESSAGE nonce counter
          @recv_nonce  = -1   # last received MESSAGE nonce (for replay detection)
        end

        # @return [Boolean] true — CURVE encrypts all post-handshake frames
        #
        def encrypted? = true

        # Performs the CurveZMQ handshake.
        #
        # @param io [#read, #write] transport IO
        # @param as_server [Boolean] (unused — tracked via @as_server)
        # @param socket_type [String]
        # @param identity [String]
        # @return [Hash] { peer_socket_type:, peer_identity: }
        # @raise [ProtocolError]
        #
        def handshake!(io, as_server:, socket_type:, identity:)
          if @as_server
            server_handshake!(io, socket_type: socket_type, identity: identity)
          else
            client_handshake!(io, socket_type: socket_type, identity: identity)
          end
        end

        # Encrypts a frame body as a CurveZMQ MESSAGE command.
        #
        # The MESSAGE plaintext is: flags_byte + body.
        # This replaces ZMTP framing — there is no ZMTP frame header inside.
        #
        # @param body [String] frame body
        # @param more [Boolean] MORE flag
        # @param command [Boolean] COMMAND flag
        # @return [String] MESSAGE command frame wire bytes (ready to write)
        #
        def encrypt(body, more: false, command: false)
          flags       = 0
          flags      |= 0x01 if more
          flags      |= 0x04 if command
          plaintext   = flags.chr.b + body.b
          nonce       = make_send_nonce
          ciphertext  = @session_box.encrypt(nonce, plaintext)
          short_nonce = nonce.byteslice(16, 8)

          msg_body = "\x07MESSAGE".b + short_nonce + ciphertext
          Codec::Frame.new(msg_body).to_wire
        end

        # Decrypts a CurveZMQ MESSAGE command into a Frame.
        #
        # @param frame [Codec::Frame] a command frame containing a MESSAGE
        # @return [Codec::Frame] decrypted frame with flags and body
        # @raise [ProtocolError] on decryption failure or nonce replay
        #
        def decrypt(frame)
          cmd = Codec::Command.from_body(frame.body)
          raise ProtocolError, "expected MESSAGE command, got #{cmd.name}" unless cmd.name == "MESSAGE"

          data = cmd.data
          raise ProtocolError, "MESSAGE too short" if data.bytesize < 8 + BOX_OVERHEAD

          short_nonce = data.byteslice(0, 8)
          ciphertext  = data.byteslice(8..)

          # Verify strictly incrementing nonce
          nonce_value = short_nonce.unpack1("Q>")
          unless nonce_value > @recv_nonce
            raise ProtocolError, "MESSAGE nonce not strictly incrementing"
          end
          @recv_nonce = nonce_value

          nonce = recv_nonce_prefix + short_nonce
          begin
            plaintext = @session_box.decrypt(nonce, ciphertext)
          rescue RbNaCl::CryptoError
            raise ProtocolError, "MESSAGE decryption failed"
          end

          flags = plaintext.getbyte(0)
          body  = plaintext.byteslice(1..) || "".b
          Codec::Frame.new(body, more: (flags & 0x01) != 0, command: (flags & 0x04) != 0)
        end

        private

        # ----------------------------------------------------------------
        # Client-side handshake
        # ----------------------------------------------------------------

        def client_handshake!(io, socket_type:, identity:)
          cn_secret = RbNaCl::PrivateKey.generate
          cn_public = cn_secret.public_key

          # --- Exchange greetings ---
          io.write(Codec::Greeting.encode(mechanism: MECHANISM_NAME, as_server: false))
          peer_greeting = Codec::Greeting.decode(read_exact(io, Codec::Greeting::SIZE))
          unless peer_greeting[:mechanism] == MECHANISM_NAME
            raise ProtocolError, "expected CURVE mechanism, got #{peer_greeting[:mechanism]}"
          end

          # --- HELLO ---
          short_nonce = [1].pack("Q>")
          nonce       = NONCE_PREFIX_HELLO + short_nonce
          hello_box   = RbNaCl::Box.new(@server_public, cn_secret)
          signature   = hello_box.encrypt(nonce, "\x00" * 64)

          hello = "".b
          hello << "\x05HELLO"
          hello << "\x01\x00"         # version 1.0
          hello << ("\x00" * 72)      # anti-amplification padding
          hello << cn_public.to_s     # 32 bytes
          hello << short_nonce        # 8 bytes
          hello << signature          # 80 bytes (64 + 16 MAC)

          io.write(Codec::Frame.new(hello, command: true).to_wire)

          # --- Read WELCOME ---
          welcome_frame = Codec::Frame.read_from(io)
          raise ProtocolError, "expected command frame" unless welcome_frame.command?
          welcome_cmd = Codec::Command.from_body(welcome_frame.body)
          raise ProtocolError, "expected WELCOME, got #{welcome_cmd.name}" unless welcome_cmd.name == "WELCOME"

          wdata = welcome_cmd.data
          # WELCOME: 16-byte random nonce + 144-byte box = 160 bytes
          raise ProtocolError, "WELCOME wrong size" unless wdata.bytesize == 16 + 144

          w_short_nonce = wdata.byteslice(0, 16)
          w_box_data    = wdata.byteslice(16, 144)
          w_nonce       = NONCE_PREFIX_WELCOME + w_short_nonce

          # WELCOME box is encrypted from server permanent to client transient
          begin
            w_plaintext = RbNaCl::Box.new(@server_public, cn_secret).decrypt(w_nonce, w_box_data)
          rescue RbNaCl::CryptoError
            raise ProtocolError, "WELCOME decryption failed"
          end

          sn_public = RbNaCl::PublicKey.new(w_plaintext.byteslice(0, 32))
          cookie    = w_plaintext.byteslice(32, 96)

          # Session box: client transient ↔ server transient
          session = RbNaCl::Box.new(sn_public, cn_secret)

          # --- INITIATE ---
          # Per RFC 26, the cookie precedes the encrypted box in cleartext.
          vouch_nonce     = NONCE_PREFIX_VOUCH + RbNaCl::Random.random_bytes(16)
          vouch_plaintext = cn_public.to_s + @server_public.to_s
          vouch           = RbNaCl::Box.new(sn_public, @permanent_secret).encrypt(vouch_nonce, vouch_plaintext)

          metadata = Codec::Command.encode_properties(
            "Socket-Type" => socket_type,
            "Identity"    => identity,
          )

          # Box contents per libzmq: client_permanent_pub + vouch_nonce_short + vouch + metadata
          initiate_box_plaintext = "".b
          initiate_box_plaintext << @permanent_public.to_s        # 32 bytes
          initiate_box_plaintext << vouch_nonce.byteslice(8, 16)  # 16-byte short vouch nonce
          initiate_box_plaintext << vouch                         # 80 bytes (64 + 16 MAC)
          initiate_box_plaintext << metadata

          init_short_nonce = [1].pack("Q>")
          init_nonce       = NONCE_PREFIX_INITIATE + init_short_nonce
          init_ciphertext  = session.encrypt(init_nonce, initiate_box_plaintext)

          # Wire format: cookie (cleartext) + short_nonce + encrypted box
          initiate = "".b
          initiate << "\x08INITIATE"
          initiate << cookie            # 96 bytes, cleartext
          initiate << init_short_nonce  # 8 bytes
          initiate << init_ciphertext

          io.write(Codec::Frame.new(initiate, command: true).to_wire)

          # --- Read READY ---
          ready_frame = Codec::Frame.read_from(io)
          raise ProtocolError, "expected command frame" unless ready_frame.command?
          ready_cmd = Codec::Command.from_body(ready_frame.body)
          raise ProtocolError, "expected READY, got #{ready_cmd.name}" unless ready_cmd.name == "READY"

          rdata = ready_cmd.data
          raise ProtocolError, "READY too short" if rdata.bytesize < 8 + BOX_OVERHEAD

          r_short_nonce = rdata.byteslice(0, 8)
          r_ciphertext  = rdata.byteslice(8..)
          r_nonce       = NONCE_PREFIX_READY + r_short_nonce

          begin
            r_plaintext = session.decrypt(r_nonce, r_ciphertext)
          rescue RbNaCl::CryptoError
            raise ProtocolError, "READY decryption failed"
          end

          props            = Codec::Command.decode_properties(r_plaintext)
          peer_socket_type = props["Socket-Type"]
          peer_identity    = props["Identity"] || ""

          @session_box = session
          @send_nonce  = 1   # READY consumed nonce 1
          @recv_nonce  = 0   # peer's READY consumed their nonce 1

          { peer_socket_type: peer_socket_type, peer_identity: peer_identity }
        end

        # ----------------------------------------------------------------
        # Server-side handshake
        # ----------------------------------------------------------------

        def server_handshake!(io, socket_type:, identity:)
          # --- Exchange greetings ---
          io.write(Codec::Greeting.encode(mechanism: MECHANISM_NAME, as_server: true))
          peer_greeting = Codec::Greeting.decode(read_exact(io, Codec::Greeting::SIZE))
          unless peer_greeting[:mechanism] == MECHANISM_NAME
            raise ProtocolError, "expected CURVE mechanism, got #{peer_greeting[:mechanism]}"
          end

          # --- Read HELLO ---
          hello_frame = Codec::Frame.read_from(io)
          raise ProtocolError, "expected command frame" unless hello_frame.command?
          hello_cmd = Codec::Command.from_body(hello_frame.body)
          raise ProtocolError, "expected HELLO, got #{hello_cmd.name}" unless hello_cmd.name == "HELLO"

          hdata = hello_cmd.data
          # version(2) + padding(72) + cn_public(32) + short_nonce(8) + signature(80) = 194
          raise ProtocolError, "HELLO wrong size (#{hdata.bytesize})" unless hdata.bytesize == 194

          cn_public     = RbNaCl::PublicKey.new(hdata.byteslice(74, 32))
          h_short_nonce = hdata.byteslice(106, 8)
          h_signature   = hdata.byteslice(114, 80)

          h_nonce = NONCE_PREFIX_HELLO + h_short_nonce
          begin
            plaintext = RbNaCl::Box.new(cn_public, @permanent_secret).decrypt(h_nonce, h_signature)
          rescue RbNaCl::CryptoError
            raise ProtocolError, "HELLO signature verification failed"
          end
          unless RbNaCl::Util.verify64(plaintext, "\x00" * 64)
            raise ProtocolError, "HELLO signature content invalid"
          end

          # --- WELCOME ---
          sn_secret = RbNaCl::PrivateKey.generate
          sn_public = sn_secret.public_key

          # Cookie: encrypt(cn_public + sn_secret) with socket-wide cookie key
          cookie_nonce     = NONCE_PREFIX_COOKIE + RbNaCl::Random.random_bytes(16)
          cookie_plaintext = cn_public.to_s + sn_secret.to_s
          cookie           = cookie_nonce.byteslice(8, 16) +
                             RbNaCl::SecretBox.new(@cookie_key).encrypt(cookie_nonce, cookie_plaintext)
          # cookie = 16 (short nonce) + 64 (plaintext) + 16 (MAC) = 96 bytes

          w_plaintext   = sn_public.to_s + cookie
          w_short_nonce = RbNaCl::Random.random_bytes(16)  # 16-byte random nonce
          w_nonce       = NONCE_PREFIX_WELCOME + w_short_nonce
          w_ciphertext  = RbNaCl::Box.new(cn_public, @permanent_secret).encrypt(w_nonce, w_plaintext)

          welcome = "".b
          welcome << "\x07WELCOME"
          welcome << w_short_nonce   # 16 bytes
          welcome << w_ciphertext    # 128 + 16 = 144 bytes

          io.write(Codec::Frame.new(welcome, command: true).to_wire)

          # Server is now stateless — sn_secret and cn_public will be recovered
          # from the cookie in INITIATE. Only @cookie_key (socket-wide) is needed.
          sn_secret = cn_public = nil

          # --- Read INITIATE ---
          init_frame = Codec::Frame.read_from(io)
          raise ProtocolError, "expected command frame" unless init_frame.command?
          init_cmd = Codec::Command.from_body(init_frame.body)
          raise ProtocolError, "expected INITIATE, got #{init_cmd.name}" unless init_cmd.name == "INITIATE"

          idata = init_cmd.data
          # cookie(96) + short_nonce(8) + box(at least BOX_OVERHEAD)
          raise ProtocolError, "INITIATE too short" if idata.bytesize < 96 + 8 + BOX_OVERHEAD

          # Cookie is in cleartext, preceding the encrypted box (per RFC 26)
          recv_cookie   = idata.byteslice(0, 96)
          i_short_nonce = idata.byteslice(96, 8)
          i_ciphertext  = idata.byteslice(104..)

          # Recover cn_public and sn_secret from the cookie
          cookie_short_nonce   = recv_cookie.byteslice(0, 16)
          cookie_ciphertext    = recv_cookie.byteslice(16, 80)
          cookie_decrypt_nonce = NONCE_PREFIX_COOKIE + cookie_short_nonce
          begin
            cookie_contents = RbNaCl::SecretBox.new(@cookie_key).decrypt(cookie_decrypt_nonce, cookie_ciphertext)
          rescue RbNaCl::CryptoError
            raise ProtocolError, "INITIATE cookie verification failed"
          end

          cn_public = RbNaCl::PublicKey.new(cookie_contents.byteslice(0, 32))
          sn_secret = RbNaCl::PrivateKey.new(cookie_contents.byteslice(32, 32))

          # Now decrypt the INITIATE box with the recovered transient keys
          session = RbNaCl::Box.new(cn_public, sn_secret)
          i_nonce = NONCE_PREFIX_INITIATE + i_short_nonce

          begin
            i_plaintext = session.decrypt(i_nonce, i_ciphertext)
          rescue RbNaCl::CryptoError
            raise ProtocolError, "INITIATE decryption failed"
          end

          # Parse: client_permanent(32) + vouch_nonce_short(16) + vouch(80) + metadata
          raise ProtocolError, "INITIATE plaintext too short" if i_plaintext.bytesize < 32 + 16 + 80

          client_permanent  = RbNaCl::PublicKey.new(i_plaintext.byteslice(0, 32))
          vouch_short_nonce = i_plaintext.byteslice(32, 16)
          vouch_ciphertext  = i_plaintext.byteslice(48, 80)
          metadata_bytes    = i_plaintext.byteslice(128..) || "".b

          # Decrypt vouch: from client permanent to server transient
          vouch_nonce = NONCE_PREFIX_VOUCH + vouch_short_nonce
          begin
            vouch_plaintext = RbNaCl::Box.new(client_permanent, sn_secret).decrypt(vouch_nonce, vouch_ciphertext)
          rescue RbNaCl::CryptoError
            raise ProtocolError, "INITIATE vouch verification failed"
          end

          raise ProtocolError, "vouch wrong size" unless vouch_plaintext.bytesize == 64

          vouch_cn     = vouch_plaintext.byteslice(0, 32)
          vouch_server = vouch_plaintext.byteslice(32, 32)

          unless RbNaCl::Util.verify32(vouch_cn, cn_public.to_s)
            raise ProtocolError, "vouch client transient key mismatch"
          end
          unless RbNaCl::Util.verify32(vouch_server, @permanent_public.to_s)
            raise ProtocolError, "vouch server key mismatch"
          end

          # Authenticate client
          if @authenticator
            client_key = client_permanent.to_s
            allowed    = if @authenticator.respond_to?(:include?)
                           @authenticator.include?(client_key)
                         else
                           @authenticator.call(client_key)
                         end
            raise ProtocolError, "client key not authorized" unless allowed
          end

          # --- READY ---
          ready_metadata = Codec::Command.encode_properties(
            "Socket-Type" => socket_type,
            "Identity"    => identity,
          )

          r_short_nonce = [1].pack("Q>")
          r_nonce       = NONCE_PREFIX_READY + r_short_nonce
          r_ciphertext  = session.encrypt(r_nonce, ready_metadata)

          ready = "".b
          ready << "\x05READY"
          ready << r_short_nonce
          ready << r_ciphertext

          io.write(Codec::Frame.new(ready, command: true).to_wire)

          props = Codec::Command.decode_properties(metadata_bytes)

          @session_box = session
          @send_nonce  = 1   # READY consumed nonce 1
          @recv_nonce  = 0   # peer's INITIATE consumed their nonce 1

          {
            peer_socket_type: props["Socket-Type"],
            peer_identity:    props["Identity"] || "",
          }
        end

        # ----------------------------------------------------------------
        # Nonce helpers
        # ----------------------------------------------------------------

        def make_send_nonce
          @send_nonce += 1
          short = [@send_nonce].pack("Q>")
          send_nonce_prefix + short
        end

        def send_nonce_prefix
          @as_server ? NONCE_PREFIX_MESSAGE_S : NONCE_PREFIX_MESSAGE_C
        end

        def recv_nonce_prefix
          @as_server ? NONCE_PREFIX_MESSAGE_C : NONCE_PREFIX_MESSAGE_S
        end
      end
    end
  end
end
