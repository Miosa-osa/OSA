defmodule OptimalSystemAgent.CLI.OpenComputers do
  @moduledoc """
  CLI handler for `osa opencomputers <verb>`.

  Verbs: status | login | connect | enable | disable | logout
  """

  @osa_dir Path.join(System.user_home!(), ".osa")
  @toml_path Path.join([@osa_dir, "open_computers.toml"])
  @fingerprint_path Path.join([@osa_dir, "open_computers.ed25519"])
  @marker_path Path.join([@osa_dir, ".open_computers_enabled"])
  @default_control_url "wss://api.miosa.ai/api/v1/opencomputers/hosts/ws"
  @env_var "OSA_OPEN_COMPUTERS_ENABLED"

  @doc "Dispatch a list of CLI args to the appropriate verb handler."
  def dispatch([verb | rest]) do
    case verb do
      "status" -> cmd_status()
      "login" -> cmd_login(rest)
      "connect" -> cmd_login(rest)
      "enable" -> cmd_enable(rest)
      "disable" -> cmd_disable()
      "logout" -> cmd_logout(rest)
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
    marker_enabled = File.exists?(@marker_path)
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
  end

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

    File.mkdir_p!(@osa_dir)

    toml = """
    control_url      = "#{control_url}"
    host_key         = "#{key}"
    fingerprint_path = "~/.osa/open_computers.ed25519"
    modes            = ["direct"]
    heartbeat_ms     = 30000
    """

    case File.write(@toml_path, toml) do
      :ok ->
        File.chmod!(@toml_path, 0o600)
        ensure_fingerprint_file()
        IO.puts("Written: #{@toml_path} (0600)")
        IO.puts("Control URL: #{control_url}")
        IO.puts("")
        IO.puts("Run `osa opencomputers enable` then restart OSA to connect.")

      {:error, reason} ->
        IO.puts("Error: cannot write #{@toml_path}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp resolve_key(opts) do
    case opts[:key] do
      nil ->
        IO.write("Paste your oc_host_* key: ")
        IO.gets("") |> String.trim()

      key ->
        key
    end
  end

  defp maybe_confirm_overwrite(true), do: :ok

  defp maybe_confirm_overwrite(_) do
    if File.exists?(@toml_path) do
      IO.write("#{@toml_path} already exists. Overwrite? [y/N] ")
      answer = IO.gets("") |> String.trim() |> String.downcase()

      unless answer in ["y", "yes"] do
        IO.puts("Aborted.")
        System.halt(0)
      end
    end
  end

  defp ensure_fingerprint_file do
    unless File.exists?(@fingerprint_path) do
      # Write a placeholder — Session.Fingerprint generates the real keypair at startup.
      # We create the file now so there is no race on first connect.
      case File.write(@fingerprint_path, "") do
        :ok -> File.chmod!(@fingerprint_path, 0o600)
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

    File.mkdir_p!(@osa_dir)
    File.write!(@marker_path, "")

    wrote_profile =
      if Keyword.get(opts, :no_profile, false) do
        false
      else
        shell = detect_shell()
        set_env_in_profile(shell)
      end

    IO.puts("OpenComputers enabled.")
    if wrote_profile, do: IO.puts("Added #{@env_var}=true to your shell profile")
    IO.puts("Marker written: #{@marker_path}")
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
    File.rm(@marker_path)

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
      IO.write("Clear host_key from #{@toml_path}? [y/N] ")
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
        IO.puts("host_key cleared from #{@toml_path}")

      _ ->
        IO.puts("No config found at #{@toml_path} — nothing to clear.")
    end

    case Process.whereis(OptimalSystemAgent.OpenComputers.Session) do
      pid when is_pid(pid) ->
        GenServer.stop(pid, :normal)
        IO.puts("Session stopped.")

      nil ->
        :ok
    end
  end

  # ── TOML helpers ─────────────────────────────────────────────────

  defp read_toml do
    case File.read(@toml_path) do
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

    File.write!(@toml_path, Enum.join(lines, "\n") <> "\n")
    File.chmod!(@toml_path, 0o600)
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
    """)
  end
end
