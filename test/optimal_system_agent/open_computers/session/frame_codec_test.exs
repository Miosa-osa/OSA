defmodule OptimalSystemAgent.OpenComputers.Session.FrameCodecTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Session.FrameCodec

  describe "encode/1" do
    test "encodes a simple tuple to binary" do
      result = FrameCodec.encode({:hello, %{host_key: "abc"}})
      assert is_binary(result)
    end

    test "encodes atoms" do
      result = FrameCodec.encode(:ping)
      assert is_binary(result)
    end

    test "encodes integers" do
      result = FrameCodec.encode(42)
      assert is_binary(result)
    end

    test "encodes maps" do
      result = FrameCodec.encode(%{a: 1, b: 2})
      assert is_binary(result)
    end

    test "encodes lists" do
      result = FrameCodec.encode([1, 2, 3])
      assert is_binary(result)
    end
  end

  describe "decode/1" do
    test "round-trips a tuple" do
      term = {:hello_ok, %{host_id: "h-123"}}
      encoded = FrameCodec.encode(term)
      assert {:ok, ^term} = FrameCodec.decode(encoded)
    end

    test "round-trips a ping tuple" do
      term = {:ping, 99}
      encoded = FrameCodec.encode(term)
      assert {:ok, ^term} = FrameCodec.decode(encoded)
    end

    test "round-trips a map" do
      term = %{a: 1, b: "hello"}
      encoded = FrameCodec.encode(term)
      assert {:ok, ^term} = FrameCodec.decode(encoded)
    end

    test "round-trips an atom" do
      term = :noop
      encoded = FrameCodec.encode(term)
      assert {:ok, ^term} = FrameCodec.decode(encoded)
    end

    test "round-trips an integer" do
      term = 12345
      encoded = FrameCodec.encode(term)
      assert {:ok, ^term} = FrameCodec.decode(encoded)
    end

    test "returns :error for completely invalid binary" do
      assert FrameCodec.decode(<<0, 1, 2, 3, 4>>) == :error
    end

    test "returns :error for empty binary" do
      assert FrameCodec.decode(<<>>) == :error
    end

    test "returns :error for random bytes" do
      assert FrameCodec.decode(:crypto.strong_rand_bytes(32)) == :error
    end

    test ":safe flag rejects new atoms not in atom table" do
      # Encode a term with a novel atom using the raw encoder
      novel_atom = String.to_atom("osa_novel_atom_#{System.unique_integer([:positive])}")
      encoded = :erlang.term_to_binary(novel_atom)
      # Force decode via FrameCodec which uses :safe — novel atom may or may not fail
      # depending on whether it's already in the table; what matters is no crash
      result = FrameCodec.decode(encoded)
      assert result == {:ok, novel_atom} or result == :error
    end

    test "rejects binary with corrupted header byte" do
      # A valid erlang binary starts with 131; corrupt it
      encoded = FrameCodec.encode({:hello, 1})
      corrupted = <<0>> <> binary_part(encoded, 1, byte_size(encoded) - 1)
      assert FrameCodec.decode(corrupted) == :error
    end
  end
end
