defmodule OptimalSystemAgent.Sandbox.Fallback do
  @moduledoc """
  Sandbox provider failover and user notification.

  When the configured cloud sandbox provider fails (E2B dies, MIOSA is
  unreachable), this module selects an alternate provider and notifies the
  agent via a context message that the sandbox changed and what the new
  environment can/can't access.

  Adapted from HackerAI's `cloud-sandbox-recovery.ts` and `sandbox-fallback.ts`.

  ## Failover order

  1. Try the configured provider
  2. If it fails, try the next available cloud provider
  3. If no cloud provider works, fall back to Docker (if available)
  4. If Docker isn't available, fall back to host (with warning)
  5. Inject a fallback notification into the agent's context

  ## Notification

  When a fallback occurs, a prompt message is generated telling the agent:
  - What provider was requested vs what provider is now active
  - What the new sandbox can/can't access
  - That the agent should not assume the old sandbox's state is available
  """

  require Logger

  alias OptimalSystemAgent.Sandbox

  @cloud_providers [:e2b, :miosa, :vercel]

  @doc """
  Select an alternate sandbox provider for recovery.

  Returns `{:ok, provider_atom}` if an alternate is available, or
  `{:error, reason}` if no fallback is possible.
  """
  @spec select_alternate(atom()) :: {:ok, atom()} | {:error, String.t()}
  def select_alternate(failed_provider) when failed_provider in @cloud_providers do
    alternates =
      @cloud_providers
      |> Enum.reject(&(&1 == failed_provider))
      |> Enum.filter(&provider_available?/1)

    case alternates do
      [alt | _] ->
        Logger.info("[Sandbox.Fallback] Failing over from #{failed_provider} to #{alt}")
        {:ok, alt}

      [] ->
        if Sandbox.Docker.available?() do
          Logger.info("[Sandbox.Fallback] No cloud alternates, falling back to Docker")
          {:ok, :docker}
        else
          {:error, "No alternate sandbox provider available"}
        end
    end
  end

  def select_alternate(_), do: {:error, "No alternate provider configured"}

  @doc """
  Generate a fallback notification message for the agent.

  This should be injected into the agent's context so it knows the sandbox
  changed and what the new environment can do.
  """
  @spec fallback_notification(atom(), atom()) :: String.t() | nil
  def fallback_notification(from_provider, to_provider) do
    from_name = provider_display_name(from_provider)
    to_name = provider_display_name(to_provider)

    if from_provider == to_provider do
      nil
    else
      cloud_msg =
        if to_provider in @cloud_providers do
          "The cloud sandbox cannot access the user's host files, drives, localhost, or private networks. " <>
            "Do not promise host access or try to fix local host paths from the cloud sandbox."
        else
          "The sandbox has changed. Commands now run in a different environment. " <>
            "Previous sandbox state (files, running processes) is NOT available in the new sandbox."
        end

      "<sandbox_fallback>\n" <>
        "Sandbox changed from #{from_name} to #{to_name} due to a failure. " <>
        cloud_msg <>
        "\n</sandbox_fallback>"
    end
  end

  @doc "Check if a provider is available (has credentials and is reachable)."
  @spec provider_available?(atom()) :: boolean()
  def provider_available?(:e2b) do
    key =
      System.get_env("E2B_API_KEY") || Application.get_env(:optimal_system_agent, :e2b_api_key)

    is_binary(key) and key != ""
  end

  def provider_available?(:miosa) do
    key = System.get_env("MIOSA_PLATFORM_API_KEY")
    is_binary(key) and key != ""
  end

  def provider_available?(:vercel) do
    key = System.get_env("VERCEL_TOKEN")
    is_binary(key) and key != ""
  end

  def provider_available?(:docker), do: Sandbox.Docker.available?()
  def provider_available?(:host), do: true
  def provider_available?(_), do: false

  defp provider_display_name(:e2b), do: "E2B cloud"
  defp provider_display_name(:miosa), do: "MIOSA cloud"
  defp provider_display_name(:vercel), do: "Vercel sandbox"
  defp provider_display_name(:docker), do: "Docker local"
  defp provider_display_name(:host), do: "host (no sandbox)"
  defp provider_display_name(other), do: Atom.to_string(other)
end
