defmodule OptimalSystemAgent.Security.ExecutionEnvironment do
  @moduledoc """
  Classifies the hybrid execution environment (cloud Kali vs Docker vs host)
  and renders the prompt blocks SecurityContext injects.

  Port scans on cloud sandboxes produce false-positives. localhost in cloud
  or Docker is the container, not the operator laptop. LAN and local
  dev-server targets need the host backend.

  Pure functions. No network. No Mix deps.
  """

  @type kind :: :cloud | :docker | :host | :ask

  @cloud_markers ~w(e2b lambda microvm cloud vercel miosa)

  @doc """
  Classify a backend module, name, atom, or config map.

  Maps use `:sandbox_backend` or `:backend` (string keys accepted).
  `Host` in the module/name -> `:host`, `Docker` -> `:docker`,
  E2B / Lambda / MicroVM / cloud / vercel / miosa -> `:cloud`.
  Nil or unknown -> `:ask`.
  """
  @spec kind(map() | atom() | module() | String.t()) :: kind()
  def kind(%{} = map) do
    map
    |> fetch_backend()
    |> classify()
  end

  def kind(value), do: classify(value)

  @doc "Cloud and ask cannot be trusted for TCP port results. Docker and host can."
  @spec port_scan_trustworthy?(kind()) :: boolean()
  def port_scan_trustworthy?(:docker), do: true
  def port_scan_trustworthy?(:host), do: true
  def port_scan_trustworthy?(:cloud), do: false
  def port_scan_trustworthy?(:ask), do: false
  def port_scan_trustworthy?(_), do: false

  @doc """
  True only for `:host`.

  Docker localhost is the container. Cloud localhost is
  the sandbox. Ask has no terminal.
  """
  @spec can_reach_localhost?(kind()) :: boolean()
  def can_reach_localhost?(:host), do: true
  def can_reach_localhost?(:docker), do: false
  def can_reach_localhost?(:cloud), do: false
  def can_reach_localhost?(:ask), do: false
  def can_reach_localhost?(_), do: false

  @doc """
  `<execution_environment>` block for the given kind.

  SecurityContext should call this from `build_sandbox_context/2` and
  `build_host_context/1`.
  """
  @spec prompt(kind()) :: String.t()
  def prompt(:cloud) do
    """
    <execution_environment>
    Kind: cloud sandbox (E2B, Lambda, MicroVM, Vercel, MIOSA, or similar).
    Commands run in an isolated cloud container, not on the operator laptop.

    Port-scan false-positives:
    - Cloud networking can produce false-positive TCP port results where many or all ports appear open. This can affect naabu, nmap TCP connect scans, nc, and other tools that rely on successful outbound connections. Changing scanner flags may not fix the underlying network behavior.
    - Treat implausible cloud port-scan output as invalid or unverified. Do not keep retrying broad scans, claim the ports are confirmed open, or blame the scanning tool when the environment is the likely cause.
    - When reliable port scanning or normal TCP, UDP, or raw-socket behavior is required, recommend the host backend so tools use that machine's native network stack. Do not keep scanning from the cloud.

    Localhost:
    - localhost and 127.0.0.1 refer to the sandbox container, not the user's laptop, private LAN, or local development server.
    - Do not use host.docker.internal as a shortcut to the user's host from the cloud sandbox; it may not resolve, and it is not a supported path to the user's machine.
    - For LAN or localhost targets, use the host backend or a user-provided tunnel URL.

    Cookies / session state:
    - Do not persist cookies or localStorage to disk because the sandbox may be reused across runs.
    - Prefer login_session_put in session memory over writing cookie files.
    </execution_environment>
    """
  end

  def prompt(:docker) do
    """
    <execution_environment>
    Kind: local Docker sandbox.
    Commands run inside the container, not on the host OS.

    Localhost:
    - localhost and 127.0.0.1 refer to the container, not the user's machine or LAN.
    - Host LAN and the user's local dev servers need the host backend or a tunnel.

    Cookies:
    - Prefer login_session_put over writing cookie files.
    </execution_environment>
    """
  end

  def prompt(:host) do
    """
    <execution_environment>
    Kind: host (no sandbox isolation).
    Commands affect the real machine. localhost IS the user's machine and LAN.

    Confirm with the operator before destructive, irreversible, credential-exfiltrating, persistence-affecting, or broad host-impacting commands unless the operator explicitly requested that exact action.
    </execution_environment>
    """
  end

  def prompt(:ask) do
    """
    <execution_environment>
    Kind: ask. No terminal environment is selected yet.
    Do not invent scans, port results, or local connectivity.
    Ask the operator to select cloud, docker, or host (or provide a tunnel URL) before running terminal commands.
    </execution_environment>
    """
  end

  def prompt(other), do: prompt(kind(other))

  @doc """
  The local-machine-access rule.

  Switching sandbox does not auto-connect to the laptop. For local or
  dev-server targets the operator must run with the host backend or
  provide a tunnel URL.
  """
  @spec local_machine_access_prompt(kind()) :: String.t()
  def local_machine_access_prompt(:host) do
    """
    <local_machine_access>
    Host backend: localhost IS the operator's machine and LAN.
    Switching sandbox does not auto-connect some other laptop. You are already on this host.
    Cloud or Docker still cannot reach this machine unless the operator provided a tunnel URL.
    For local or dev-server targets this host backend is the correct choice.
    </local_machine_access>
    """
  end

  def local_machine_access_prompt(:ask) do
    """
    <local_machine_access>
    Switching sandbox does not auto-connect to the laptop.
    No terminal environment is selected yet.
    For local or dev-server targets the operator must run with the host backend or provide a tunnel URL.
    Do not invent a route to the laptop.
    </local_machine_access>
    """
  end

  def local_machine_access_prompt(kind) when kind in [:cloud, :docker] do
    """
    <local_machine_access>
    Switching sandbox does not auto-connect to the laptop.
    The sandbox cannot access the user's actual machine, local filesystem, or private LAN.
    In this environment, localhost and 127.0.0.1 refer to the sandbox/container, not the user's laptop.
    For local or dev-server targets the operator must run with the host backend or provide a tunnel URL.
    </local_machine_access>
    """
  end

  def local_machine_access_prompt(other), do: local_machine_access_prompt(kind(other))

  # ── Classify ──────────────────────────────────────────────────────────

  defp fetch_backend(map) do
    Map.get(map, :sandbox_backend) ||
      Map.get(map, "sandbox_backend") ||
      Map.get(map, :backend) ||
      Map.get(map, "backend")
  end

  defp classify(kind) when kind in [:cloud, :docker, :host, :ask], do: kind
  defp classify(nil), do: :ask
  defp classify(""), do: :ask

  defp classify(value) when is_atom(value) or is_binary(value) do
    name = value |> to_string() |> String.downcase()

    cond do
      String.contains?(name, "host") -> :host
      String.contains?(name, "docker") -> :docker
      Enum.any?(@cloud_markers, &String.contains?(name, &1)) -> :cloud
      true -> :ask
    end
  end

  defp classify(_), do: :ask
end
