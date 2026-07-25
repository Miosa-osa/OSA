defmodule OptimalSystemAgent.OpenComputers.Remote do
  @moduledoc """
  Account-scoped remote control operations for OpenComputers hosts.

  This is separate from the host daemon session.  The host uses its
  `oc_host_*` grant to connect outward.  A person uses their existing MIOSA
  account key to open one short-lived remote session to one host they own.
  """

  alias OptimalSystemAgent.MIOSA.Platform
  alias OptimalSystemAgent.OpenComputers.Remote.Client

  @type options :: keyword()

  @spec list_hosts(options()) :: {:ok, [map()]} | {:error, term()}
  def list_hosts(opts \\ []) do
    with_client(opts, fn client ->
      case Client.request(client, {:remote_hosts_list, %{}}, &match?({:remote_hosts, _}, &1)) do
        {:ok, client, {:remote_hosts, %{hosts: hosts}}} when is_list(hosts) ->
          {:ok, client, hosts}

        {:ok, client, frame} ->
          {:error, client, {:unexpected_frame, frame}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec exec(binary(), binary(), options()) :: {:ok, map()} | {:error, term()}
  def exec(host_id, command, opts \\ []) when is_binary(host_id) and is_binary(command) do
    with_session(host_id, :exec, %{cmd: command}, opts, fn client, session_id, request_id ->
      case Client.receive_frames(
             client,
             &job_terminal?(&1, session_id),
             timeout(opts),
             request_id
           ) do
        {:ok, client,
         {:remote_session_frame,
          %{session_id: ^session_id, frame: {:job_done, ^session_id, result}}}} ->
          {:ok, client, result}

        {:ok, client,
         {:remote_session_frame,
          %{session_id: ^session_id, frame: {:job_fail, ^session_id, error}}}} ->
          {:error, client, error}

        {:ok, client, frame} ->
          {:error, client, {:unexpected_frame, frame}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec dispatch_agent(binary(), binary(), map(), options()) :: {:ok, map()} | {:error, term()}
  def dispatch_agent(host_id, prompt, context \\ %{}, opts \\ [])
      when is_binary(host_id) and is_binary(prompt) and is_map(context) do
    with_session(host_id, :agent, %{prompt: prompt, context: context}, opts, fn client,
                                                                                session_id,
                                                                                request_id ->
      case Client.receive_frames(
             client,
             &job_terminal?(&1, session_id),
             timeout(opts),
             request_id
           ) do
        {:ok, client,
         {:remote_session_frame,
          %{session_id: ^session_id, frame: {:job_done, ^session_id, result}}}} ->
          {:ok, client, result}

        {:ok, client,
         {:remote_session_frame,
          %{session_id: ^session_id, frame: {:job_fail, ^session_id, error}}}} ->
          {:error, client, error}

        {:ok, client, frame} ->
          {:error, client, {:unexpected_frame, frame}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp with_session(host_id, kind, params, opts, fun) do
    with_client(opts, fn client ->
      ref = Ecto.UUID.generate()
      frame = {:remote_session_open, %{ref: ref, host_id: host_id, kind: kind, params: params}}

      case Client.request(
             client,
             frame,
             &match?({:remote_session_opened, _}, &1),
             timeout(opts),
             ref
           ) do
        {:ok, client, {:remote_session_opened, %{session_id: session_id}}}
        when is_binary(session_id) ->
          result = fun.(client, session_id, ref)
          close_session(client, session_id)

          case result do
            {:ok, client, value} -> {:ok, client, value}
            {:error, client, reason} -> {:error, client, reason}
            {:error, reason} -> {:error, reason}
          end

        {:ok, client, frame} ->
          {:error, client, {:unexpected_frame, frame}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp close_session(client, session_id) do
    _ =
      Client.request(
        client,
        {:remote_session_close, %{session_id: session_id, reason: :client_closed}},
        fn _ -> false end,
        0
      )

    :ok
  end

  defp with_client(opts, fun) do
    account_key = Keyword.get(opts, :account_key, Platform.platform_api_key())

    if is_binary(account_key) and account_key != "" do
      case Client.connect(Keyword.put(opts, :account_key, account_key)) do
        {:ok, client} ->
          result = fun.(client)

          case result do
            {:ok, returned_client, value} ->
              Client.close(returned_client)
              {:ok, value}

            {:error, returned_client, reason} ->
              Client.close(returned_client)
              {:error, reason}

            {:error, reason} ->
              Client.close(client)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :missing_platform_api_key}
    end
  end

  defp job_terminal?(
         {:remote_session_frame, %{session_id: session_id, frame: {:job_done, session_id, _}}},
         session_id
       ),
       do: true

  defp job_terminal?(
         {:remote_session_frame, %{session_id: session_id, frame: {:job_fail, session_id, _}}},
         session_id
       ),
       do: true

  defp job_terminal?(_, _), do: false

  defp timeout(opts), do: Keyword.get(opts, :timeout, :timer.minutes(5))
end
