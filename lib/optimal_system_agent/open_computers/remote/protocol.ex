defmodule OptimalSystemAgent.OpenComputers.Remote.Protocol do
  @moduledoc """
  Versioned wire contract for OpenComputers remote clients.

  The public client never sends a host frame directly.
  It sends one validated remote operation inside this envelope, and the
  control plane turns that operation into the appropriate host frame only
  after ownership and capability checks pass.
  """

  @version 1

  @type body ::
          {:remote_hello, map()}
          | {:remote_hosts_list, map()}
          | {:remote_session_open, map()}
          | {:remote_session_close, map()}
          | {:pong, integer()}

  @spec envelope(body(), binary()) :: {:oc_remote, map()}
  def envelope(body, request_id \\ Ecto.UUID.generate()) when is_binary(request_id) do
    {:oc_remote, %{v: @version, request_id: request_id, body: body}}
  end

  @spec unwrap(term()) :: {:ok, binary(), term()} | {:error, :invalid_envelope}
  def unwrap({:oc_remote, %{v: @version, request_id: request_id, body: body}})
      when is_binary(request_id) do
    {:ok, request_id, body}
  end

  def unwrap(_), do: {:error, :invalid_envelope}

  @doc "The only operation bodies a public v1 client may originate."
  @spec client_body?(term()) :: boolean()
  def client_body?({:remote_hello, %{account_key: key, client_instance_id: id}})
      when is_binary(key) and byte_size(key) > 0 and is_binary(id),
      do: true

  def client_body?({:remote_hosts_list, %{}}), do: true

  def client_body?(
        {:remote_session_open, %{ref: ref, host_id: host_id, kind: kind, params: params}}
      )
      when is_binary(ref) and is_binary(host_id) and kind in [:exec, :agent] and is_map(params),
      do: true

  def client_body?({:remote_session_close, %{session_id: session_id, reason: reason}})
      when is_binary(session_id) and reason in [:client_closed, :cancelled],
      do: true

  def client_body?({:pong, seq}) when is_integer(seq), do: true
  def client_body?(_), do: false
end
