defmodule OptimalSystemAgent.CLI.Update do
  @moduledoc """
  CLI handlers for `osa update {check,apply,disable}`.

  Subcommands:
    * `osa update check`   — check for available update, print current + latest
    * `osa update apply`   — manually trigger download + stage (check + download now)
    * `osa update disable` — write `[update] enabled = false` to ~/.osa/open_computers.toml

  All subcommands work without the full OTP application running because they
  either just write a config file or start a minimal subset of the app.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Updater

  @config_path Path.expand("~/.osa/open_computers.toml")

  # ---------------------------------------------------------------------------
  # Public entry points (called from CLI dispatcher)
  # ---------------------------------------------------------------------------

  @doc "osa update check — print current version, poll for latest."
  def check do
    ensure_started()

    current = current_version()
    IO.puts("Current version:  #{current}")

    case Updater.check_now() do
      {:ok, :up_to_date} ->
        IO.puts("Latest version:   #{current} (up to date)")

      {:ok, {:staged, version}} ->
        IO.puts("Latest version:   #{version}")
        IO.puts("Status:           STAGED — restart OSA to apply update")

      {:error, reason} ->
        IO.puts("Check failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc "osa update apply — same as check but always downloads if update is available."
  def apply_update do
    ensure_started()

    current = current_version()
    IO.puts("Current version:  #{current}")
    IO.puts("Checking for updates...")

    case Updater.check_now() do
      {:ok, :up_to_date} ->
        IO.puts("Already up to date (#{current})")

      {:ok, {:staged, version}} ->
        IO.puts("Update #{version} staged at ~/.osa/bin/osa.new")
        IO.puts("Restart OSA to apply.")

      {:error, reason} ->
        IO.puts("Update failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc "osa update disable — write [update] enabled = false to config."
  def disable do
    File.mkdir_p!(Path.dirname(@config_path))

    current_contents =
      case File.read(@config_path) do
        {:ok, c} -> c
        {:error, _} -> ""
      end

    updated = set_update_enabled(current_contents, false)
    File.write!(@config_path, updated)
    IO.puts("Auto-update disabled. Edit #{@config_path} to re-enable.")
  end

  @doc "osa update enable — write [update] enabled = true to config."
  def enable do
    File.mkdir_p!(Path.dirname(@config_path))

    current_contents =
      case File.read(@config_path) do
        {:ok, c} -> c
        {:error, _} -> ""
      end

    updated = set_update_enabled(current_contents, true)
    File.write!(@config_path, updated)
    IO.puts("Auto-update enabled.")
  end

  @doc """
  Public test helper — produce updated TOML content with enabled flag set.
  Called by tests as `CLI.Update.build_toml_with_enabled(contents, bool)`.
  """
  @spec build_toml_with_enabled(String.t(), boolean()) :: String.t()
  def build_toml_with_enabled(contents, enabled), do: set_update_enabled(contents, enabled)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp ensure_started do
    # Start minimal dependencies for the HTTP check
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:jason)
  end

  defp current_version do
    Application.load(:optimal_system_agent)
    Application.spec(:optimal_system_agent, :vsn) |> to_string()
  rescue
    _ ->
      case File.read("VERSION") do
        {:ok, v} -> String.trim(v)
        _ -> "unknown"
      end
  end

  # Set `enabled = true|false` in the [update] section of a TOML file.
  # Creates the section if absent.
  defp set_update_enabled(contents, enabled) do
    enabled_str = if enabled, do: "true", else: "false"
    lines = String.split(contents, "\n")

    {result_lines, found_section, set_key} =
      Enum.reduce(lines, {[], false, false}, fn line, {acc, in_section, key_set} ->
        trimmed = String.trim(line)

        cond do
          trimmed == "[update]" ->
            {[line | acc], true, key_set}

          in_section and String.starts_with?(trimmed, "enabled") and
              String.contains?(trimmed, "=") ->
            {["enabled = #{enabled_str}" | acc], in_section, true}

          in_section and String.starts_with?(trimmed, "[") and trimmed != "[update]" ->
            # Entering a new section — inject the key before this section if not set
            if key_set do
              {[line | acc], false, key_set}
            else
              {[line, "enabled = #{enabled_str}" | acc], false, true}
            end

          true ->
            {[line | acc], in_section, key_set}
        end
      end)

    output_lines = Enum.reverse(result_lines)

    # If we never found the [update] section, append it
    if not found_section and not set_key do
      existing = Enum.join(output_lines, "\n") |> String.trim_trailing()
      separator = if existing == "", do: "", else: "\n\n"
      "#{existing}#{separator}[update]\nenabled = #{enabled_str}\n"
    else
      # If we found the section but never saw the key (section at EOF), append
      final =
        if found_section and not set_key do
          output_lines ++ ["enabled = #{enabled_str}"]
        else
          output_lines
        end

      Enum.join(final, "\n")
    end
  end
end
