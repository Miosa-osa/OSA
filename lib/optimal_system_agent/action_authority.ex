defmodule OptimalSystemAgent.ActionAuthority do
  @moduledoc """
  The single OSA adapter to MIOSA's durable action authority.

  OSA keeps its local, non-bypassable safety checks for protecting the machine
  it runs on.
  This module answers a different question: whether the authenticated MIOSA
  principal may perform a governed platform action in the selected tenant and
  workspace.

  Governed actions fail closed.
  Ungoverned local tools do not make a network request.
  Capability versions and fingerprints always come from the control plane's
  catalog, never from OSA-owned policy.
  """

  require Logger

  alias OptimalSystemAgent.MIOSA.Platform
  alias OptimalSystemAgent.Sandbox

  @type decision ::
          :not_governed
          | {:allow, map()}
          | {:blocked, String.t()}

  @default_timeout_ms 10_000

  @doc """
  Authorize one tool invocation at the final execution boundary.

  The default mapping governs `shell_execute` only when its selected backend is
  MIOSA. Additional exact tool-to-capability mappings can be supplied through
  `config :optimal_system_agent, :action_authority, capability_map: %{...}`.
  """
  @spec authorize_tool(String.t(), map()) :: decision()
  def authorize_tool(tool_name, arguments) when is_binary(tool_name) and is_map(arguments) do
    case capability_for(tool_name, arguments) do
      nil ->
        :not_governed

      capability_name ->
        authorize(
          capability_name,
          tool_name,
          public_arguments(arguments),
          surface(arguments)
        )
    end
  end

  def authorize_tool(_tool_name, _arguments),
    do: {:blocked, "central action authority received an invalid tool invocation"}

  @doc "Cross-language stable SHA-256 fingerprint of canonical JSON."
  @spec fingerprint(term()) :: String.t()
  def fingerprint(value) do
    digest = :crypto.hash(:sha256, canonical_json(value)) |> Base.encode16(case: :lower)
    "sha256:" <> digest
  end

  @doc "Canonical JSON with recursively sorted object keys."
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, child} -> {to_string(key), child} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, child} ->
        Jason.encode!(key) <> ":" <> canonical_json(child)
      end)

    "{" <> pairs <> "}"
  end

  def canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  def canonical_json(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or
             is_nil(value),
      do: Jason.encode!(value)

  def canonical_json(value),
    do:
      raise(
        ArgumentError,
        "authority fingerprints require JSON-safe values, got: #{inspect(value)}"
      )

  defp authorize(capability_name, tool_name, arguments, surface) do
    with {:ok, key} <- require_platform_key(),
         {:ok, capability} <- fetch_capability(capability_name, key),
         {:ok, response} <- request_decision(capability, tool_name, arguments, surface, key) do
      interpret(response)
    else
      {:error, reason} ->
        Logger.error(
          "[ActionAuthority] blocked #{tool_name}/#{capability_name}: #{inspect(reason)}"
        )

        {:blocked, failure_message(reason)}
    end
  end

  defp capability_for(tool_name, arguments) do
    configured =
      authority_config()
      |> Keyword.get(:capability_map, %{})
      |> Map.get(tool_name)

    cond do
      is_binary(configured) ->
        configured

      tool_name == "shell_execute" and miosa_sandbox?(arguments) ->
        "sandbox.exec"

      true ->
        nil
    end
  end

  defp miosa_sandbox?(_arguments) do
    Sandbox.Router.backend() == Sandbox.MIOSA
  end

  defp require_platform_key do
    case Platform.platform_api_key() do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :platform_auth_missing}
    end
  end

  defp fetch_capability(name, key) do
    case request(:get, "/api/v1/actions/catalog", key, []) do
      {:ok, 200, %{"data" => catalog}} when is_list(catalog) ->
        case Enum.find(catalog, &(&1["name"] == name)) do
          %{"fingerprint" => fingerprint} = capability
          when is_binary(fingerprint) and fingerprint != "" ->
            {:ok, capability}

          _ ->
            {:error, {:capability_not_registered, name}}
        end

      {:ok, status, body} ->
        {:error, {:catalog_http_error, status, body}}

      {:error, reason} ->
        {:error, {:catalog_unavailable, reason}}
    end
  end

  defp request_decision(capability, tool_name, arguments, surface, key) do
    workspace_id = Platform.workspace_id()
    params_fingerprint = fingerprint(arguments)

    invocation = %{
      capability: capability["fingerprint"],
      params: params_fingerprint,
      surface: surface,
      tool: tool_name,
      workspace_id: workspace_id
    }

    body = %{
      capability: %{
        name: capability["name"],
        fingerprint: capability["fingerprint"]
      },
      request_fingerprint: fingerprint(invocation),
      params_fingerprint: params_fingerprint,
      surface: surface
    }

    body = if workspace_id, do: Map.put(body, :workspace_id, workspace_id), else: body

    case request(:post, "/api/v1/actions/authorize", key, json: body) do
      {:ok, status, response} when status in [200, 202, 403] -> {:ok, response}
      {:ok, status, response} -> {:error, {:authorize_http_error, status, response}}
      {:error, reason} -> {:error, {:authority_unavailable, reason}}
    end
  end

  defp interpret(%{"decision" => "allow"} = response), do: {:allow, response}

  defp interpret(%{
         "decision" => "pending_approval",
         "approval_request_id" => approval_request_id
       }) do
    {:blocked,
     "central approval required before this action can run (approval #{approval_request_id})"}
  end

  defp interpret(%{"decision" => "deny"} = response) do
    {:blocked, "central action authority denied this action#{reason_suffix(response)}"}
  end

  defp interpret(response),
    do: {:blocked, "central action authority returned an invalid decision: #{inspect(response)}"}

  defp request(method, path, key, options) do
    config = authority_config()

    request_options =
      [
        method: method,
        url: base_url(config) <> path,
        headers: [{"authorization", "Bearer " <> key}],
        receive_timeout: Keyword.get(config, :timeout_ms, @default_timeout_ms),
        retry: false
      ]
      |> Keyword.merge(options)
      |> maybe_put_plug(config)

    case Req.request(request_options) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp maybe_put_plug(options, config) do
    case Keyword.get(config, :plug) do
      nil -> options
      plug -> Keyword.put(options, :plug, plug)
    end
  end

  defp base_url(config) do
    config
    |> Keyword.get(:base_url, Platform.endpoint())
    |> String.trim_trailing("/")
  end

  defp authority_config do
    Application.get_env(:optimal_system_agent, :action_authority, [])
  end

  defp public_arguments(arguments) do
    Map.drop(arguments, [
      "__session_id__",
      :__session_id__,
      "__surface__",
      :__surface__
    ])
  end

  defp surface(arguments) do
    arguments["__surface__"] || arguments[:__surface__] || "osa"
  end

  defp reason_suffix(%{"reason" => reason}) when is_binary(reason), do: ": " <> reason
  defp reason_suffix(_response), do: ""

  defp failure_message(:platform_auth_missing),
    do: "central action authority is required, but MIOSA platform authentication is missing"

  defp failure_message({:capability_not_registered, name}),
    do: "central action authority has no registered capability named #{name}"

  defp failure_message(reason),
    do: "central action authority is unavailable or invalid: #{inspect(reason)}"
end
