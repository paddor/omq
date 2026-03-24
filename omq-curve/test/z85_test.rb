# frozen_string_literal: true

require_relative "test_helper"

describe OMQ::Z85 do
  # Test vector from RFC 32
  it "encodes the RFC 32 test vector" do
    binary = [0x86, 0x4F, 0xD2, 0x6F, 0xB5, 0x59, 0xF7, 0x5B].pack("C*")
    assert_equal "HelloWorld", OMQ::Z85.encode(binary)
  end

  it "decodes the RFC 32 test vector" do
    expected = [0x86, 0x4F, 0xD2, 0x6F, 0xB5, 0x59, 0xF7, 0x5B].pack("C*")
    assert_equal expected, OMQ::Z85.decode("HelloWorld")
  end

  it "round-trips a 32-byte key" do
    key = RbNaCl::Random.random_bytes(32)
    encoded = OMQ::Z85.encode(key)
    assert_equal 40, encoded.length
    assert_equal key, OMQ::Z85.decode(encoded)
  end

  it "round-trips all zeros" do
    data = "\x00" * 4
    decoded = OMQ::Z85.decode(OMQ::Z85.encode(data))
    assert_equal data.b, decoded
  end

  it "round-trips all 0xFF" do
    data = "\xFF" * 4
    decoded = OMQ::Z85.decode(OMQ::Z85.encode(data))
    assert_equal data.b, decoded
  end

  it "raises on non-multiple-of-4 input for encode" do
    assert_raises(ArgumentError) { OMQ::Z85.encode("abc") }
  end

  it "raises on non-multiple-of-5 input for decode" do
    assert_raises(ArgumentError) { OMQ::Z85.decode("abcd") }
  end

  it "raises on invalid Z85 characters" do
    assert_raises(ArgumentError) { OMQ::Z85.decode("Hell\x00") }
  end
end
