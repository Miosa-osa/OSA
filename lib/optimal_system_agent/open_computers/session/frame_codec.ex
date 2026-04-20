defmodule OptimalSystemAgent.OpenComputers.Session.FrameCodec do
  @moduledoc """
  Erlterm encode/decode for OpenComputers WS frames.

  ALL decodes use `:safe` to prevent arbitrary-atom creation from
  untrusted control-plane input.
  """

  @spec decode(binary()) :: {:ok, term()} | :error
  def decode(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term)
end
