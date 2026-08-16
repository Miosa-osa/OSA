defmodule OptimalSystemAgent.Security.TrustContentPinningTest do
  @moduledoc """
  Accepting workspace trust once must not be a standing grant over whatever the
  repository's config becomes later.

  Before pinning, `/trust accept` recorded only the directory. A `git pull`
  that added a `PreToolUse` hook, an `env` entry or an MCP server to
  `.osa/settings.json` was then honoured silently and forever — the user
  approved a directory in one state and got a different one.

  Trust is now pinned to a digest of the SECURITY-RELEVANT config at accept
  time. Preference keys are deliberately excluded, so ordinary editing never
  costs a re-prompt.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Workspace.Cwd
  alias OptimalSystemAgent.Workspace.Trust

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-trust-pin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".osa"))

    write = fn content ->
      File.write!(Path.join(dir, ".osa/settings.json"), Jason.encode!(content))
      # Ensure a distinct mtime so the stat-based latch cannot mask a change.
      Settings.reset_cache()
    end

    write.(%{"skin" => "dark", "permissions" => %{"allow" => ["file_read"]}})

    Cwd.put_process_override(dir)
    Trust.forget(dir)

    on_exit(fn ->
      Trust.forget(dir)
      File.rm_rf(dir)
      Settings.reset_cache()
    end)

    {:ok, dir: dir, write: write}
  end

  test "baseline: accepting trust makes the config effective", %{dir: dir} do
    refute Trust.trusted?(dir)
    Trust.accept(dir)
    assert Trust.trusted?(dir)
  end

  test "adding a hook after trust re-prompts (the git-pull attack)", %{dir: dir, write: write} do
    Trust.accept(dir)
    assert Trust.trusted?(dir)

    # The repo updates: a hook that did not exist when the user accepted.
    write.(%{
      "skin" => "dark",
      "permissions" => %{"allow" => ["file_read"]},
      "hooks" => %{"PreToolUse" => [%{"command" => "/tmp/pwn.sh"}]}
    })

    refute Trust.trusted?(dir)
    assert Settings.trusted_layer(:project) == %{}
  end

  test "status/1 distinguishes 'config changed' from 'never trusted'", %{dir: dir, write: write} do
    refute Trust.status(dir).trusted
    refute Trust.status(dir).config_changed, "a never-trusted dir has not 'changed'"

    Trust.accept(dir)
    assert Trust.status(dir).trusted
    refute Trust.status(dir).config_changed

    write.(%{"permissions" => %{"allow" => ["file_read"]}, "env" => %{"LD_PRELOAD" => "/x"}})

    status = Trust.status(dir)
    refute status.trusted
    assert status.config_changed, "the dialog must be able to say WHY trust lapsed"
  end

  test "widening the allow list after trust re-prompts", %{dir: dir, write: write} do
    Trust.accept(dir)
    assert Trust.trusted?(dir)

    write.(%{"skin" => "dark", "permissions" => %{"allow" => ["file_read", "shell_execute"]}})

    refute Trust.trusted?(dir)
  end

  test "adding env after trust re-prompts (LD_PRELOAD = code injection)", %{
    dir: dir,
    write: write
  } do
    Trust.accept(dir)

    write.(%{
      "permissions" => %{"allow" => ["file_read"]},
      "env" => %{"LD_PRELOAD" => "/tmp/e.so"}
    })

    refute Trust.trusted?(dir)
  end

  test "adding a project MCP server after trust re-prompts", %{dir: dir} do
    Trust.accept(dir)
    assert Trust.trusted?(dir)

    File.write!(
      Path.join(dir, ".mcp.json"),
      Jason.encode!(%{"mcpServers" => %{"pwn" => %{"command" => "/bin/sh"}}})
    )

    refute Trust.trusted?(dir)
  end

  test "adding a hook SCRIPT after trust re-prompts", %{dir: dir} do
    Trust.accept(dir)
    assert Trust.trusted?(dir)

    hooks = Path.join([dir, ".osa", "hooks"])
    File.mkdir_p!(hooks)
    File.write!(Path.join(hooks, "pre.sh"), "#!/bin/sh\ntouch /tmp/PWNED\n")

    refute Trust.trusted?(dir)
  end

  test "editing a hook script IN PLACE re-prompts (dir mtime alone is not enough)", %{dir: dir} do
    hooks = Path.join([dir, ".osa", "hooks"])
    File.mkdir_p!(hooks)
    File.write!(Path.join(hooks, "pre.sh"), "#!/bin/sh\necho ok\n")

    Trust.accept(dir)
    assert Trust.trusted?(dir)

    File.write!(Path.join(hooks, "pre.sh"), "#!/bin/sh\ntouch /tmp/PWNED\n")

    refute Trust.trusted?(dir)
  end

  describe "legitimate workflows are not disturbed" do
    test "editing a NON-security preference key never re-prompts", %{dir: dir, write: write} do
      Trust.accept(dir)
      assert Trust.trusted?(dir)

      write.(%{"skin" => "light", "verbose" => true, "permissions" => %{"allow" => ["file_read"]}})

      assert Trust.trusted?(dir), "changing skin/verbose must not cost a re-prompt"
    end

    test "reformatting the file (key order, whitespace) never re-prompts", %{dir: dir} do
      Trust.accept(dir)
      assert Trust.trusted?(dir)

      File.write!(
        Path.join(dir, ".osa/settings.json"),
        ~s({\n  "permissions" : {\n    "allow" : [ "file_read" ]\n  },\n  "skin": "dark"\n}\n)
      )

      assert Trust.trusted?(dir), "a purely cosmetic rewrite must not cost a re-prompt"
    end

    test "re-accepting after a real change restores trust", %{dir: dir, write: write} do
      Trust.accept(dir)
      write.(%{"permissions" => %{"allow" => ["file_read", "shell_execute"]}})
      refute Trust.trusted?(dir)

      Trust.accept(dir)
      assert Trust.trusted?(dir)
    end

    test "trust INHERITED from a parent is not pinned (a broad grant stays broad)", %{dir: dir} do
      child = Path.join(dir, "sub/repo")
      File.mkdir_p!(Path.join(child, ".osa"))

      Trust.accept(dir)
      assert Trust.trusted?(child)

      # The child gains its own executable config. The user trusted the whole
      # parent tree deliberately, so this is inside the grant they gave.
      File.write!(
        Path.join(child, ".osa/settings.json"),
        Jason.encode!(%{"hooks" => %{"PreToolUse" => [%{"command" => "x"}]}})
      )

      assert Trust.trusted?(child)
    end

    test "a grant with no digest (written before pinning) stays trusted", %{dir: dir} do
      # Simulate a legacy store entry.
      Trust.accept(dir)

      store_path =
        Path.join(System.get_env("OSA_HOME") || Path.expand("~/.osa"), "trusted_workspaces.json")

      store = store_path |> File.read!() |> Jason.decode!()
      legacy = Map.update!(store, Path.expand(dir), &Map.delete(&1, "config_digest"))
      File.write!(store_path, Jason.encode!(legacy))
      :persistent_term.erase({Trust, :latch, Path.expand(dir)})

      File.write!(
        Path.join(dir, ".osa/settings.json"),
        Jason.encode!(%{"hooks" => %{"PreToolUse" => [%{"command" => "x"}]}})
      )

      assert Trust.trusted?(dir), "legacy grants are grandfathered, not silently revoked"
    end
  end
end
