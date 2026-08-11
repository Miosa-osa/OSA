defmodule OptimalSystemAgent.CLI.UpdateConfigWriteTest do
  @moduledoc """
  `osa update enable|disable` derives the WHOLE new open_computers.toml from
  what it reads. Two ways that used to go wrong, both silent:

    * `{:error, _} -> ""` treated EACCES/EIO/EISDIR as "no file yet", so a
      config that merely could not be read was replaced by a two-line stub and
      every other setting in it was destroyed.

    * `File.write!` truncates in place, so a crash mid-write leaves an
      unparseable TOML — the very file that decides whether updates run.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.CLI.Update

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-update-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      File.chmod(Path.join(dir, "open_computers.toml"), 0o600)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, toml: Path.join(dir, "open_computers.toml")}
  end

  defp silence(fun), do: ExUnit.CaptureIO.capture_io(fun)

  describe "happy path" do
    test "creates the file when absent and sets enabled = false", %{toml: toml} do
      silence(fn -> Update.disable() end)
      assert File.read!(toml) =~ "[update]"
      assert File.read!(toml) =~ "enabled = false"
    end

    test "flips an existing flag without discarding neighbouring settings", %{toml: toml} do
      File.write!(toml, """
      [gateway]
      port = 18789
      token = "keep-me"

      [update]
      enabled = true

      [telemetry]
      enabled = true
      """)

      silence(fn -> Update.disable() end)

      contents = File.read!(toml)
      assert contents =~ "port = 18789"
      assert contents =~ ~s(token = "keep-me")
      assert contents =~ "[telemetry]"
      assert contents =~ "enabled = false"
    end

    test "enable/0 round-trips back to true", %{toml: toml} do
      silence(fn -> Update.disable() end)
      assert File.read!(toml) =~ "enabled = false"
      silence(fn -> Update.enable() end)
      assert File.read!(toml) =~ "enabled = true"
    end
  end

  describe "read failures must not destroy the config" do
    test "an unreadable-but-writable config is refused loudly, not rewritten as a stub",
         %{toml: toml} do
      original = """
      [gateway]
      port = 18789
      token = "precious"

      [providers]
      anthropic_api_key = "sk-ant-precious"
      """

      File.write!(toml, original)
      # 0200 — write-only — is the mode that actually isolates this defect.
      # With 0000 the subsequent write would fail too, so the old code raised
      # anyway and the bug stayed hidden. Unreadable BUT writable is the case
      # where `{:error, _} -> ""` silently succeeded at destroying the file:
      # read fails, "" is used as the base, and the derived stub writes fine.
      File.chmod!(toml, 0o200)

      if File.read(toml) == {:error, :eacces} do
        assert_raise File.Error, fn -> silence(fn -> Update.disable() end) end

        File.chmod!(toml, 0o600)
        # Every byte still there. The old code left a 2-line [update] stub.
        assert File.read!(toml) == original
      else
        # root / permissive FS: EACCES is not reachable.
        :ok
      end
    end

    test "a directory where the config should be does not produce a stub write", %{dir: dir} do
      # EISDIR is another error the old `{:error, _}` arm swallowed.
      path = Path.join(dir, "open_computers.toml")
      File.mkdir_p!(Path.join(path, "child"))

      assert_raise File.Error, fn -> silence(fn -> Update.disable() end) end
      assert File.dir?(path)
    end

    test "a genuinely missing file is still treated as empty (enoent is not an error)",
         %{toml: toml} do
      refute File.exists?(toml)
      silence(fn -> Update.enable() end)
      assert File.read!(toml) =~ "enabled = true"
    end
  end

  # These two were NOT broken before: plain `File.write!` opens the existing
  # path, so it follows symlinks and keeps the inode's mode for free. They
  # guard the fix itself — switching to temp-file + rename is exactly what
  # WOULD have broken both, had the helper not resolved links and carried the
  # mode across.
  describe "the write itself" do
    test "is atomic: no temp file survives and content is complete", %{dir: dir, toml: toml} do
      silence(fn -> Update.disable() end)

      assert File.ls!(dir) == ["open_computers.toml"]
      assert File.read!(toml) =~ "enabled = false"
    end

    test "a config symlinked into a dotfiles repo stays a symlink", %{dir: dir, toml: toml} do
      real = Path.join(dir, "dotfiles_open_computers.toml")

      File.write!(real, """
      [gateway]
      port = 18789
      """)

      :ok = File.ln_s(real, toml)

      silence(fn -> Update.disable() end)

      assert File.lstat!(toml).type == :symlink,
             "the user's symlink was replaced by a regular file"

      assert File.read!(real) =~ "enabled = false"
      assert File.read!(real) =~ "port = 18789"
    end

    test "preserves the config's mode across a rewrite", %{toml: toml} do
      File.write!(toml, "[update]\nenabled = true\n")
      File.chmod!(toml, 0o600)

      silence(fn -> Update.disable() end)

      assert Bitwise.band(File.stat!(toml).mode, 0o777) == 0o600
    end
  end
end
