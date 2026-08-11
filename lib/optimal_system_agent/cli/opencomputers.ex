defmodule OptimalSystemAgent.CLI.OpenComputers do
  @moduledoc """
  CLI handler for `osa opencomputers <verb>`.

  Verbs: status | login | connect | enable | disable | logout | remote
  """

  defp osa_dir, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")
  defp toml_path, do: Path.join([osa_dir(), "open_computers.toml"])
  defp fingerprint_path, do: Path.join([osa_dir(), "open_computers.ed25519"])
  defp marker_path, do: Path.join([osa_dir(), ".open_computers_enabled"])
  @default_control_url "wss://api.miosa.ai/api/v1/opencomputers/hosts/ws"
  @env_var "OSA_OPEN_COMPUTERS_ENABLED"
  # Where a user generates a host key. The control plane is api.miosa.ai;
  # the dashboard that mints oc_host_* keys lives at the app host.
  @dashboard_url "https://miosa.ai/settings/computers"

  @doc "Dispatch a list of CLI args to the appropriate verb handler."
  def dispatch([verb | rest]) do
    case verb do
      "status" -> cmd_status()
      "login" -> cmd_login(rest)
      "connect" -> cmd_login(rest)
      "enable" -> cmd_enable(rest)
      "disable" -> cmd_disable()
      "logout" -> cmd_logout(rest)
      "remote" -> cmd_remote(rest)
      _ -> usage()
    end
  end

  def dispatch([]) do
    usage()
  end

  # ── status ──────────────────────────────────────────────────────

  defp cmd_status do
    cfg = read_toml()
    config_enabled = Application.get_env(:optimal_system_agent, :open_computers_enabled, false)
    env_enabled = System.get_env(@env_var) == "true"
    marker_enabled = File.exists?(marker_path())
    enabled = config_enabled or env_enabled or marker_enabled

    IO.puts("")
    IO.puts("OpenComputers Status")
    IO.puts("────────────────────────────────")
    IO.puts("  Enabled:      #{if enabled, do: "yes", else: "no"}")
    IO.puts("  Config flag:  #{config_enabled}")
    IO.puts("  Env var:      #{@env_var}=#{System.get_env(@env_var) || "(unset)"}")

    IO.puts(
      "  Marker file:  #{if marker_enabled, do: "~/.osa/.open_computers_enabled", else: "(none)"}"
    )

    IO.puts("")
    IO.puts("  Control URL:  #{cfg[:control_url] || @default_control_url}")
    IO.puts("  Host key:     #{redact_key(cfg[:host_key])}")
    IO.puts("  Fingerprint:  #{cfg[:fingerprint_path] || "~/.osa/open_computers.ed25519"}")
    IO.puts("  Modes:        #{cfg[:modes] || "[\"direct\"]"}")
    IO.puts("  Heartbeat ms: #{cfg[:heartbeat_ms] || 30_000}")
    IO.puts("")
    IO.puts("  Supervisor:   #{supervisor_status()}")
    IO.puts("  Session:      #{session_status()}")
    IO.puts("")

    has_key = present?(cfg[:host_key])
    {verdict, hint} = connection_verdict(enabled, has_key, session_status())
    IO.puts("  Status: #{verdict}")
    if hint, do: IO.puts("  Next:   #{hint}")
    IO.puts("")
  end

  @doc false
  # Pure summariser used by `status`: given whether the extension is enabled,
  # whether a host_key is present, and the human session-status string, return
  # {verdict, next_step_hint_or_nil}. Extracted so it can be tested without
  # touching live processes or the network.
  @spec connection_verdict(boolean(), boolean(), String.t()) :: {String.t(), String.t() | nil}
  def connection_verdict(_enabled, false, _session) do
    {"NOT connected — no host key configured",
     "run `osa opencomputers login` (generate a key at #{@dashboard_url})"}
  end

  def connection_verdict(false, true, _session) do
    {"NOT connected — extension disabled", "run `osa opencomputers enable` then restart OSA"}
  end

  def connection_verdict(true, true, session) do
    cond do
      String.starts_with?(session, "connected") ->
        {"CONNECTED — this machine is online in MIOSA", nil}

      session == "not running" ->
        {"NOT connected — enabled but session not started", "restart OSA to start the connection"}

      true ->
        {"connecting — session running but not yet active",
         "check network / host key; `osa opencomputers status` again in a moment"}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  defp redact_key(nil), do: "(not set)"
  defp redact_key(""), do: "(not set)"

  defp redact_key(key) when byte_size(key) > 12 do
    last4 = String.slice(key, -4, 4)
    prefix = String.slice(key, 0, 7)
    "#{prefix}***...#{last4}"
  end

  defp redact_key(key), do: String.slice(key, 0, 3) <> "***"

  defp supervisor_status do
    case Process.whereis(OptimalSystemAgent.OpenComputers.Supervisor) do
      pid when is_pid(pid) -> "running (#{inspect(pid)})"
      nil -> "not running"
    end
  end

  defp session_status do
    case Process.whereis(OptimalSystemAgent.OpenComputers.Session) do
      pid when is_pid(pid) ->
        try do
          %{phase: phase} = :sys.get_state(pid, 2_000)
          if phase == :active, do: "connected (active)", else: "running (phase=#{phase})"
        rescue
          _ -> "running"
        catch
          :exit, _ -> "running"
        end

      nil ->
        "not running"
    end
  end

  # ── login ────────────────────────────────────────────────────────

  defp cmd_login(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [key: :string, control_url: :string, force: :boolean]
      )

    key = resolve_key(opts)

    if is_nil(key) or String.trim(key) == "" do
      IO.puts("Error: no key provided.")
      System.halt(1)
    end

    key = String.trim(key)
    control_url = opts[:control_url] || @default_control_url

    maybe_confirm_overwrite(opts[:force])

    File.mkdir_p!(osa_dir())

    toml = """
    control_url      = "#{control_url}"
    host_key         = "#{key}"
    fingerprint_path = "~/.osa/open_computers.ed25519"
    modes            = ["direct"]
    heartbeat_ms     = 30000
    """

    case File.write(toml_path(), toml) do
      :ok ->
        File.chmod!(toml_path(), 0o600)
        ensure_fingerprint_file()
        IO.puts("Host key saved: #{toml_path()} (0600)")
        IO.puts("Control URL:   #{control_url}")
        IO.puts("")
        IO.puts("Next steps to bring this machine online in MIOSA:")
        IO.puts("  1. osa opencomputers enable      # turn on host mode")
        IO.puts("  2. restart OSA                   # so the connection starts")
        IO.puts("  3. osa opencomputers status      # confirm 'Session: connected (active)'")
        IO.puts("")
        IO.puts("Once connected, the machine appears in your MIOSA dashboard as a Computer.")

      {:error, reason} ->
        IO.puts("Error: cannot write #{toml_path()}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp resolve_key(opts) do
    case opts[:key] do
      nil ->
        IO.puts("")
        IO.puts("To connect this machine to MIOSA you need a host key (oc_host_...).")
        IO.puts("Generate one in your MIOSA account settings:")
        IO.puts("  #{@dashboard_url}")
        IO.puts("")
        IO.write("Paste your oc_host_* key: ")
        IO.gets("") |> String.trim()

      key ->
        key
    end
  end

  defp maybe_confirm_overwrite(true), do: :ok

  defp maybe_confirm_overwrite(_) do
    if File.exists?(toml_path()) do
      IO.write("#{toml_path()} already exists. Overwrite? [y/N] ")
      answer = IO.gets("") |> String.trim() |> String.downcase()

      unless answer in ["y", "yes"] do
        IO.puts("Aborted.")
        System.halt(0)
      end
    end
  end

  defp ensure_fingerprint_file do
    unless File.exists?(fingerprint_path()) do
      # Write a placeholder — Session.Fingerprint generates the real keypair at startup.
      # We create the file now so there is no race on first connect.
      case File.write(fingerprint_path(), "") do
        :ok -> File.chmod!(fingerprint_path(), 0o600)
        _ -> :ok
      end
    end
  end

  # ── enable ───────────────────────────────────────────────────────

  defp cmd_enable(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [profile: :boolean, no_profile: :boolean]
      )

    File.mkdir_p!(osa_dir())
    File.write!(marker_path(), "")

    wrote_profile =
      if Keyword.get(opts, :no_profile, false) do
        false
      else
        shell = detect_shell()
        set_env_in_profile(shell)
      end

    IO.puts("OpenComputers enabled.")
    if wrote_profile, do: IO.puts("Added #{@env_var}=true to your shell profile")
    IO.puts("Marker written: #{marker_path()}")
    IO.puts("")

    if is_nil(Process.whereis(OptimalSystemAgent.OpenComputers.Supervisor)) do
      IO.puts("Supervisor not running. Restart OSA to activate.")
    else
      IO.puts("Supervisor already running — extension is live.")
    end
  end

  defp detect_shell do
    case System.get_env("SHELL") do
      shell when is_binary(shell) ->
        cond do
          String.ends_with?(shell, "zsh") -> :zsh
          String.ends_with?(shell, "bash") -> :bash
          String.ends_with?(shell, "fish") -> :fish
          true -> :unknown
        end

      nil ->
        :unknown
    end
  end

  defp shell_profile(:zsh), do: Path.join(System.user_home!(), ".zshrc")
  defp shell_profile(:bash), do: Path.join(System.user_home!(), ".bashrc")
  defp shell_profile(_), do: nil

  defp set_env_in_profile(:fish) do
    IO.puts("Fish shell detected. Add manually to ~/.config/fish/config.fish:")
    IO.puts("  set -x #{@env_var} true")
    false
  end

  defp set_env_in_profile(:unknown) do
    IO.puts("Unknown shell. Set manually: export #{@env_var}=true")
    false
  end

  defp set_env_in_profile(shell) do
    profile = shell_profile(shell)
    line = "export #{@env_var}=true"

    existing =
      case File.read(profile) do
        {:ok, content} -> content
        _ -> ""
      end

    if String.contains?(existing, @env_var) do
      false
    else
      File.write!(profile, existing <> "\n#{line}\n")
      true
    end
  end

  # ── disable ──────────────────────────────────────────────────────

  defp cmd_disable do
    File.rm(marker_path())

    shell = detect_shell()
    remove_env_from_profile(shell)

    case Process.whereis(OptimalSystemAgent.OpenComputers.Supervisor) do
      pid when is_pid(pid) ->
        Supervisor.stop(pid, :normal)
        IO.puts("Supervisor stopped.")

      nil ->
        :ok
    end

    IO.puts("OpenComputers disabled.")
    IO.puts("Marker removed. Restart shell for profile change to take effect.")
  end

  defp remove_env_from_profile(:fish) do
    IO.puts(
      "Fish shell: remove `set -x #{@env_var} true` from ~/.config/fish/config.fish manually."
    )
  end

  defp remove_env_from_profile(:unknown) do
    IO.puts("Unknown shell: remove `export #{@env_var}=true` from your shell profile manually.")
  end

  defp remove_env_from_profile(shell) do
    profile = shell_profile(shell)

    case File.read(profile) do
      {:ok, content} ->
        updated =
          content
          |> String.split("\n")
          |> Enum.reject(&String.contains?(&1, @env_var))
          |> Enum.join("\n")

        File.write!(profile, updated)
        IO.puts("Removed #{@env_var} from #{profile}")

      _ ->
        :ok
    end
  end

  # ── logout ───────────────────────────────────────────────────────

  defp cmd_logout(args) do
    {opts, _} = OptionParser.parse!(args, strict: [force: :boolean])

    unless opts[:force] do
      IO.write("Clear host_key from #{toml_path()}? [y/N] ")
      answer = IO.gets("") |> String.trim() |> String.downcase()

      unless answer in ["y", "yes"] do
        IO.puts("Aborted.")
        System.halt(0)
      end
    end

    case read_toml() do
      cfg when map_size(cfg) > 0 ->
        updated = Map.put(cfg, :host_key, "")
        write_toml(updated)
        IO.puts("host_key cleared from #{toml_path()}")

      _ ->
        IO.puts("No config found at #{toml_path()} — nothing to clear.")
    end

    case Process.whereis(OptimalSystemAgent.OpenComputers.Session) do
      pid when is_pid(pid) ->
        GenServer.stop(pid, :normal)
        IO.puts("Session stopped.")

      nil ->
        :ok
    end
  end

  # ── remote client ─────────────────────────────────────────────────

  # Host mode owns a machine with an oc_host_* grant. Remote mode is for a
  # person using their existing MIOSA account credential to reach a host they
  # own. Keeping both verbs here makes the credential boundary visible.
  defp cmd_remote(["hosts" | args]) do
    opts = remote_opts(args)

    case OptimalSystemAgent.OpenComputers.Remote.list_hosts(opts) do
      {:ok, hosts} ->
        Enum.each(hosts, fn host ->
          IO.puts(
            [
              Map.get(host, :id, "unknown"),
              Map.get(host, :name, Map.get(host, :alias, "")),
              if(Map.get(host, :online, false), do: "online", else: "offline")
            ]
            |> Enum.join("\t")
          )
        end)

      {:error, reason} ->
        remote_error(reason)
    end
  end

  defp cmd_remote(["exec" | args]) do
    {opts, command_args, _} =
      OptionParser.parse(args,
        strict: [host: :string, url: :string, timeout: :integer, account_key: :string],
        aliases: [h: :host]
      )

    host_id = opts[:host]
    command = Enum.join(command_args, " ")

    if is_binary(host_id) and host_id != "" and command != "" do
      case OptimalSystemAgent.OpenComputers.Remote.exec(
             host_id,
             command,
             normalize_remote_opts(opts)
           ) do
        {:ok, result} -> IO.puts(format_remote_result(result))
        {:error, reason} -> remote_error(reason)
      end
    else
      IO.puts("Usage: osa opencomputers remote exec --host <host-id> -- <command>")
      System.halt(2)
    end
  end

  defp cmd_remote(["agent" | args]) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          prompt: :string,
          url: :string,
          timeout: :integer,
          account_key: :string
        ],
        aliases: [h: :host, p: :prompt]
      )

    if is_binary(opts[:host]) and opts[:host] != "" and is_binary(opts[:prompt]) and
         opts[:prompt] != "" do
      case OptimalSystemAgent.OpenComputers.Remote.dispatch_agent(
             opts[:host],
             opts[:prompt],
             %{},
             normalize_remote_opts(opts)
           ) do
        {:ok, result} -> IO.puts(format_remote_result(result))
        {:error, reason} -> remote_error(reason)
      end
    else
      IO.puts("Usage: osa opencomputers remote agent --host <host-id> --prompt <prompt>")
      System.halt(2)
    end
  end

  defp cmd_remote(_args) do
    IO.puts("Usage: osa opencomputers remote <hosts|exec|agent> ...")
    System.halt(2)
  end

  defp remote_opts(args) do
    {opts, _rest, _} =
      OptionParser.parse(args, strict: [url: :string, timeout: :integer, account_key: :string])

    normalize_remote_opts(opts)
  end

  defp normalize_remote_opts(opts) do
    opts
    |> Keyword.take([:url, :account_key, :timeout])
    |> maybe_timeout(opts[:timeout])
  end

  defp maybe_timeout(opts, nil), do: opts

  defp maybe_timeout(opts, seconds) when is_integer(seconds) and seconds > 0,
    do: Keyword.put(opts, :timeout, :timer.seconds(seconds))

  defp maybe_timeout(opts, _), do: opts

  defp format_remote_result(%{result: result}), do: to_string(result)
  defp format_remote_result(%{"result" => result}), do: to_string(result)
  defp format_remote_result(result) when is_binary(result), do: result
  defp format_remote_result(result), do: inspect(result)

  defp remote_error(:missing_platform_api_key) do
    IO.puts("No MIOSA account key found. Run `miosa login` or set MIOSA_PLATFORM_API_KEY.")
    System.halt(1)
  end

  defp remote_error(reason) do
    IO.puts("OpenComputers remote request failed: #{inspect(reason)}")
    System.halt(1)
  end

  # ── TOML helpers ─────────────────────────────────────────────────

  defp read_toml do
    case File.read(toml_path()) do
      {:ok, body} -> parse_toml(body)
      _ -> %{}
    end
  end

  defp parse_toml(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          acc

        String.contains?(line, "=") ->
          [k, v] = String.split(line, "=", parts: 2)
          key = k |> String.trim() |> String.to_atom()
          Map.put(acc, key, parse_toml_value(String.trim(v)))

        true ->
          acc
      end
    end)
  end

  defp parse_toml_value("\"" <> rest), do: String.trim_trailing(rest, "\"")

  defp parse_toml_value("[" <> rest) do
    rest
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_toml_value/1)
  end

  defp parse_toml_value(other) do
    case Integer.parse(other) do
      {n, ""} -> n
      _ -> other
    end
  end

  defp write_toml(cfg) do
    lines = [
      ~s(control_url      = "#{cfg[:control_url] || @default_control_url}"),
      ~s(host_key         = "#{cfg[:host_key] || ""}"),
      ~s(fingerprint_path = "#{cfg[:fingerprint_path] || "~/.osa/open_computers.ed25519"}"),
      ~s(modes            = #{format_modes(cfg[:modes])}),
      ~s(heartbeat_ms     = #{cfg[:heartbeat_ms] || 30_000})
    ]

    File.write!(toml_path(), Enum.join(lines, "\n") <> "\n")
    File.chmod!(toml_path(), 0o600)
  end

  defp format_modes(nil), do: ~s(["direct"])

  defp format_modes(modes) when is_list(modes),
    do: "[#{Enum.map_join(modes, ", ", &~s("#{&1}"))}]"

  defp format_modes(modes), do: modes

  # ── Usage ─────────────────────────────────────────────────────────

  defp usage do
    IO.puts("""
    Usage: osa opencomputers <verb>

    Verbs:
      status                         Print config + connection state
      login [--key <key>]            Write host key to ~/.osa/open_computers.toml
      connect [--key <key>]          Alias for login
            [--control-url <url>]    (default: #{@default_control_url})
            [--force]                Skip overwrite confirmation
      enable [--no-profile]          Enable host mode; optionally skip shell profile edits
      disable                        Remove env var + stop running supervisor
      logout [--force]               Clear host_key and stop session
      remote hosts                   List your online OpenComputers hosts
      remote exec --host <id> -- <command>
                                    Run one command on a host you own
      remote agent --host <id> --prompt <prompt>
                                    Dispatch OSA's local agent on a host you own

    Remote commands use the existing MIOSA platform key from `miosa login`
    or `MIOSA_PLATFORM_API_KEY`. They never use or store an `oc_host_*` key.
    """)
  end
end
