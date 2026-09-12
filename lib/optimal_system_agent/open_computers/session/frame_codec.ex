defmodule OptimalSystemAgent.OpenComputers.Session.FrameCodec do
  @moduledoc """
  Erlterm encode/decode for OpenComputers WS frames.

  ALL decodes use `:safe` to prevent arbitrary-atom creation from
  untrusted control-plane input.
  """

  # Safe ETF decoding requires these fixed protocol atoms to exist before the
  # first hello/job is decoded. Executor modules are lazily loaded in releases.
  @desktop_wire_atoms [
    :hello_ok,
    :host_id,
    :owner_tenant_id,
    :assigned_tenant_ids,
    :control_plane_version,
    :heartbeat_ms,
    :desktop_session_grant,
    :tenant_id,
    :session_id,
    :scope,
    :expires_at,
    :desktop_start_request,
    :allow_input,
    :width,
    :height,
    :display,
    :desktop_data,
    :direction,
    :upstream,
    :data,
    :desktop_stop,
    :job,
    :id,
    :kind,
    :stream_native_desktop,
    :relay_url,
    :grant,
    :node_id
  ]

  @doc false
  def desktop_wire_atoms, do: @desktop_wire_atoms

  @spec decode(binary()) :: {:ok, term()} | :error
  def decode(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term)
end
