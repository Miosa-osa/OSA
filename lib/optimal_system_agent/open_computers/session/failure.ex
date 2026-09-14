defmodule OptimalSystemAgent.OpenComputers.Session.Failure do
  @moduledoc """
  Safe session failure policy shared by reconnect handling and status reporting.
  Remote text, HTTP headers, credentials and exception messages never enter diagnostics.
  A non-nil action pauses automatic reconnect until operator correction and restart.
  """

  def close(code) do
    {reason, action} =
      case code do
        4001 ->
          {:auth, auth_action()}

        4003 ->
          {:upgrade_required, protocol_action()}

        4004 ->
          {:fingerprint_pinned,
           "Verify this host's registered fingerprint with the administrator, then restart OSA."}

        4007 ->
          {:key_revoked,
           "Obtain a new host key and run `osa opencomputers login --key <key>`, then restart OSA."}

        4008 ->
          {:timeout, nil}

        _ ->
          {:transient, nil}
      end

    code = if is_integer(code) and code in 1000..4999, do: code, else: :unknown
    %{source: :server_close, code: code, reason: reason, action: action}
  end

  def handshake({:http_status, status}) do
    {reason, action} =
      if status in [401, 403], do: {:auth, auth_action()}, else: {:http_error, nil}

    %{source: :handshake, status: status, reason: reason, action: action}
  end

  def handshake(reason) when reason in [:subprotocol_mismatch, :invalid_upgrade] do
    %{source: :handshake, reason: reason, action: protocol_action()}
  end

  def transport(reason), do: %{source: :transport, reason: transport_reason(reason), action: nil}

  def transport_reason(%Mint.TransportError{reason: reason}), do: transport_reason(reason)

  def transport_reason(reason)
      when reason in [
             :closed,
             :timeout,
             :econnrefused,
             :nxdomain,
             :enetunreach,
             :ehostunreach,
             :upgrade_timeout,
             :upgrade_transport_error,
             :connect_exception
           ],
      do: reason

  def transport_reason(_), do: :transport_error

  def describe(failure) do
    detail =
      cond do
        Map.has_key?(failure, :code) -> "code=#{failure.code} "
        Map.has_key?(failure, :status) -> "status=#{failure.status} "
        true -> ""
      end

    "#{failure.source} #{detail}reason=#{failure.reason}"
  end

  defp auth_action,
    do: "Run `osa opencomputers login --key <key>` with a valid host key, then restart OSA."

  defp protocol_action,
    do: "Update OSA and verify the control-plane WebSocket subprotocol, then restart OSA."
end
