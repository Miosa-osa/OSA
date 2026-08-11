defmodule OptimalSystemAgent.OpenComputers.UpdaterTest do
  @moduledoc """
  Unit tests for OptimalSystemAgent.OpenComputers.Updater.

  Uses mocked HTTP via Req.Test to avoid real network calls.

  Tests:
  - Version comparison: newer version triggers download, same/older does not
  - SHA256 mismatch aborts download and leaves bin unchanged
  - Successful download stages osa.new at ~/.osa/bin/osa.new
  - update_enabled: false config no-ops on periodic check
  - Platform detection returns expected string format
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Updater

  @tmp_dir System.tmp_dir!()

  setup do
    # Use a temp directory as the fake home for each test
    home = Path.join([@tmp_dir, "osa_updater_test_#{:erlang.unique_integer([:positive])}"])
    bin_dir = Path.join([home, ".osa", "bin"])
    File.mkdir_p!(bin_dir)

    # Override home detection
    original_home = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      case original_home do
        nil -> System.delete_env("HOME")
        v -> System.put_env("HOME", v)
      end

      File.rm_rf!(home)
    end)

    {:ok, home: home, bin_dir: bin_dir}
  end

  # ── version comparison ───────────────────────────────────────────────────────

  describe "version_newer?/2 (via check_now with mocked HTTP)" do
    test "up_to_date when manifest version matches current" do
      manifest = build_manifest("0.3.0")

      with_mock_http(manifest, fn ->
        {:ok, pid} = start_updater(current_version: "0.3.0")
        result = GenServer.call(pid, :check_now, 5_000)
        assert result == {:ok, :up_to_date}
        GenServer.stop(pid)
      end)
    end

    test "up_to_date when manifest version is older than current" do
      manifest = build_manifest("0.2.9")

      with_mock_http(manifest, fn ->
        {:ok, pid} = start_updater(current_version: "0.3.0")
        result = GenServer.call(pid, :check_now, 5_000)
        assert result == {:ok, :up_to_date}
        GenServer.stop(pid)
      end)
    end

    test "reports {:available, version} when the latest release is newer" do
      manifest = build_manifest("0.4.0")

      with_mock_http(manifest, fn ->
        {:ok, pid} = start_updater(current_version: "0.3.0")
        result = GenServer.call(pid, :check_now, 5_000)
        # Check-only: reports availability, does NOT stage (the launcher applies).
        assert result == {:ok, {:available, "0.4.0"}}
        GenServer.stop(pid)
      end)
    end

    test "handles the zero-padded display tag (v1.0.034 vs current 1.0.34) as up_to_date" do
      # GitHub tags are padded ("v1.0.034"); Version.parse rejects the leading zero
      # unless normalize_version strips it. Same numeric version must NOT be flagged
      # as an available update.
      manifest = build_manifest("1.0.034")

      with_mock_http(manifest, fn ->
        {:ok, pid} = start_updater(current_version: "1.0.34")
        result = GenServer.call(pid, :check_now, 5_000)
        assert result == {:ok, :up_to_date}
        GenServer.stop(pid)
      end)
    end

    test "reports available across the padding boundary (v1.0.035 > 1.0.34)" do
      manifest = build_manifest("1.0.035")

      with_mock_http(manifest, fn ->
        {:ok, pid} = start_updater(current_version: "1.0.34")
        result = GenServer.call(pid, :check_now, 5_000)
        # Reports the actual release tag (OSA's padded display convention).
        assert result == {:ok, {:available, "1.0.035"}}
        GenServer.stop(pid)
      end)
    end
  end

  # ── disabled update ──────────────────────────────────────────────────────────

  describe "update disabled" do
    test "check_now still works even when periodic loop is disabled" do
      manifest = build_manifest("0.3.0")

      with_mock_http(manifest, fn ->
        # Disable periodic checks but check_now should still function
        {:ok, pid} = start_updater(current_version: "0.3.0", enabled: false)
        result = GenServer.call(pid, :check_now, 5_000)
        # Up to date
        assert result == {:ok, :up_to_date}
        GenServer.stop(pid)
      end)
    end
  end

  # ── CLI.Update helpers ───────────────────────────────────────────────────────

  describe "CLI.Update.set_update_enabled (TOML writer)" do
    test "creates [update] section in empty file" do
      result = OptimalSystemAgent.CLI.Update.build_toml_with_enabled("", false)
      assert String.contains?(result, "[update]")
      assert String.contains?(result, "enabled = false")
    end

    test "sets enabled = false in existing [update] section" do
      existing = "[update]\nenabled = true\nchannel = \"stable\"\n"
      result = OptimalSystemAgent.CLI.Update.build_toml_with_enabled(existing, false)
      assert String.contains?(result, "enabled = false")
      refute String.contains?(result, "enabled = true")
      assert String.contains?(result, "channel = \"stable\"")
    end

    test "sets enabled = true in existing [update] section" do
      existing = "[update]\nenabled = false\n"
      result = OptimalSystemAgent.CLI.Update.build_toml_with_enabled(existing, true)
      assert String.contains?(result, "enabled = true")
      refute String.contains?(result, "enabled = false")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Mimics the GitHub Releases `/releases/latest` payload the updater now reads.
  # `version` is a bare semver (e.g. "0.4.0" or padded "1.0.034"); GitHub tags it
  # with a leading "v", which the updater strips.
  defp build_manifest(version) do
    %{
      "tag_name" => "v#{version}",
      "name" => "OSA v#{version}",
      "published_at" => "2026-04-19T00:00:00Z"
    }
  end

  defp with_mock_http(manifest, fun) do
    # Register Req stub — all requests through plug: {Req.Test, Updater} will use this
    Req.Test.stub(OptimalSystemAgent.OpenComputers.Updater, fn conn ->
      Req.Test.json(conn, manifest)
    end)

    fun.()
  end

  defp start_updater(opts) do
    current_version = Keyword.get(opts, :current_version, "0.3.0")
    enabled = Keyword.get(opts, :enabled, true)

    # Override current version so the updater sees the test value
    Application.put_env(
      :optimal_system_agent,
      :__test_version_override__,
      current_version
    )

    name = :"Updater_#{:erlang.unique_integer([:positive])}"

    # Pass the Req.Test plug so HTTP is intercepted without real network calls.
    # Allow the stub to be used from the GenServer process (Req.Test ownership).
    result =
      GenServer.start_link(
        Updater,
        [enabled: enabled, plug: {Req.Test, Updater}],
        name: name
      )

    case result do
      {:ok, pid} ->
        # Allow the GenServer process to access the Req.Test stub
        Req.Test.allow(OptimalSystemAgent.OpenComputers.Updater, self(), pid)

      _ ->
        :ok
    end

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :__test_version_override__)
    end)

    result
  end
end
