defmodule OptimalSystemAgent.OpenComputers.Session.FrameCodec do
  @moduledoc """
  Binary frame encode/decode for the OpenComputers WebSocket protocol.

  Frames are Erlang external term format (`:erlang.term_to_binary` /
  `:erlang.binary_to_term`). The control-plane uses the same codec
  (`Web.Ws.OpenComputers.FrameCodec`).

  All **decodes** from the control plane use `:safe` to prevent arbitrary
  atom creation from untrusted input. Encoding for outgoing frames uses
  the standard term serializer.
  """

  @doc "Decode a binary frame from the control plane. Returns `{:ok, term}` or `:error`."
  @spec decode(binary()) :: {:ok, term()} | :error
  def decode(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  @doc "Encode a term to a binary WebSocket frame payload."
  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term)
end
