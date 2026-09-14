defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.BackendTest do
  @moduledoc """
  Pins the defect: a `file_grep` served by the fallback because ripgrep is
  missing must SAY SO, on every surface.

  The bug these tests exist to prevent recurring: `System.cmd("rg", …)` raises
  `:enoent` off the daemon's PATH, a bare `rescue` turned that into a fallback,
  and nothing anywhere mentioned it. All 862 `file_grep` calls in a 118-session
  corpus were served that way. A search answering from 0.9% of the tree while
  claiming "No matches found." is worse than one that errors, because nothing
  looks broken.

  These tests are deliberately written so they pass on a machine WITH ripgrep and
  a machine WITHOUT it — the assertions are about the reporting contract, not
  about this particular box's PATH. `PATH=""` is used to force the missing case
  regardless of the host, so CI proves the missing-binary branch even where
  ripgrep is installed.
  """
  # async: false — these tests mutate the process-global PATH env var.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Tools.Builtins.FileGrep
  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Backend

  setup do
    original_path = System.get_env("PATH")

    on_exit(fn ->
      if original_path, do: System.put_env("PATH", original_path)
      Backend.reset_warnings()
    end)

    Backend.reset_warnings()
    :ok
  end

  # Emptying PATH is what makes this test suite honest on any host: it is the
  # same condition the daemon is in when it is launched from a desktop entry or
  # a service manager, which never read a shell profile.
  defp without_ripgrep(fun) do
    System.put_env("PATH", "")
    fun.()
  end

  defp tmp_dir(tag) do
    dir =
      System.tmp_dir!()
      |> OptimalSystemAgent.Agent.Safety.PathCanon.canonicalize()
      |> Path.join("osa_grep_backend_#{tag}_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "detection" do
    test "executable/0 returns nil when ripgrep is not on the PATH" do
      without_ripgrep(fn ->
        assert Backend.executable() == nil
        refute Backend.available?()
      end)
    end
  end

  describe "osa doctor surfaces the degradation" do
    test "status/0 reports :optional and names both the impact and the fix" do
      without_ripgrep(fn ->
        assert {:optional, detail} = Backend.status()

        # It must name the missing thing...
        assert detail =~ "ripgrep"
        # ...say what it costs, in terms that stop someone trusting the answer...
        assert detail =~ "fallback"
        assert detail =~ "lower bound"
        # ...and say how to fix it.
        assert detail =~ "install" or detail =~ "Install"
      end)
    end

    test "status/0 is :optional, never :fail — the fallback works, it is just degraded" do
      without_ripgrep(fn ->
        assert {status, _} = Backend.status()
        # :fail would make `osa doctor` print NOT READY over a missing optional
        # accelerator, which trains users to ignore the readiness line.
        assert status == :optional
      end)
    end

    test "the doctor check list includes the search backend row" do
      names = Enum.map(OptimalSystemAgent.CLI.Doctor.checks(), fn {_s, name, _d} -> name end)
      assert "Search backend" in names
    end
  end

  describe "the log says so, once per session" do
    test "warn_missing_once/1 logs at :warning the first time" do
      ctx = %OptimalSystemAgent.Tools.UseContext{session_id: "sess-a"}

      log = capture_log(fn -> Backend.warn_missing_once(ctx) end)

      assert log =~ "ripgrep"
      assert log =~ "[warning]"
      assert log =~ "file_grep"
    end

    test "warn_missing_once/1 does NOT log again for the same session" do
      ctx = %OptimalSystemAgent.Tools.UseContext{session_id: "sess-b"}

      assert capture_log(fn -> Backend.warn_missing_once(ctx) end) =~ "ripgrep"

      # 862 identical lines is not a signal — it is noise that teaches people to
      # filter the channel the signal arrives on.
      assert capture_log(fn -> Backend.warn_missing_once(ctx) end) == ""
    end

    test "warn_missing_once/1 logs again for a DIFFERENT session" do
      a = %OptimalSystemAgent.Tools.UseContext{session_id: "sess-c"}
      b = %OptimalSystemAgent.Tools.UseContext{session_id: "sess-d"}

      assert capture_log(fn -> Backend.warn_missing_once(a) end) =~ "ripgrep"
      # A user who starts a session an hour later must see the notice in THEIR
      # session's log window, not have to scroll back to the last node restart.
      assert capture_log(fn -> Backend.warn_missing_once(b) end) =~ "ripgrep"
    end

    test "a real search with no ripgrep emits the warning" do
      dir = tmp_dir("warns")
      File.write!(Path.join(dir, "a.ex"), "hello\n")

      log =
        capture_log(fn ->
          without_ripgrep(fn ->
            assert {:ok, _} = FileGrep.execute(%{"pattern" => "hello", "path" => dir})
          end)
        end)

      assert log =~ "ripgrep"
    end
  end

  describe "the tool result names the backend when it finds nothing" do
    test "an empty fallback result says the answer did not come from ripgrep" do
      dir = tmp_dir("empty")
      File.write!(Path.join(dir, "a.ex"), "hello world\n")

      without_ripgrep(fn ->
        assert {:ok, out} =
                 FileGrep.execute(%{"pattern" => "zzz_definitely_absent_zzz", "path" => dir})

        assert out =~ "Backend:"
        assert out =~ "pure-Elixir fallback"
        # The critical sentence: without it, "No matches found." is a claim of
        # absence the model has no way to discount.
        assert out =~ "did NOT come from ripgrep"
      end)
    end

    test "empty_result_note/1 is silent for the ripgrep backend" do
      # The good path must not pay tokens for a caveat that does not apply.
      assert Backend.empty_result_note(:ripgrep) == ""
    end

    test "the note distinguishes 'ripgrep missing' from 'ripgrep failed'" do
      missing = Backend.empty_result_note({:fallback, :missing})
      failed = Backend.empty_result_note({:fallback, :failed})

      refute missing == failed
      assert missing =~ "not on this machine's PATH"
      # Different fault, different fix — collapsing the two is what made the
      # environment problem invisible for 862 consecutive calls.
      assert failed =~ "IS installed"
    end

    test "a fallback result that FOUND matches is not burdened with the note" do
      dir = tmp_dir("found")
      File.write!(Path.join(dir, "a.ex"), "findme\n")

      without_ripgrep(fn ->
        assert {:ok, out} = FileGrep.execute(%{"pattern" => "findme", "path" => dir})
        assert out =~ "findme"
        # A search that found something has proved it can see the tree.
        refute out =~ "Backend:"
      end)
    end
  end

  describe "the missing binary is never mistaken for 'no matches'" do
    test "a missing PATH does not turn a real match into a not-found" do
      dir = tmp_dir("regress")
      nested = Path.join([dir, "src", "deep", "nested"])
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "target.ex"), "UNIQUE_SENTINEL_TOKEN\n")

      without_ripgrep(fn ->
        assert {:ok, out} =
                 FileGrep.execute(%{"pattern" => "UNIQUE_SENTINEL_TOKEN", "path" => dir})

        # The fallback must walk the whole tree, not the first N lexicographic
        # entries — this is the 0.9%-of-54,905-files defect.
        assert out =~ "UNIQUE_SENTINEL_TOKEN"
        assert out =~ "target.ex"
      end)
    end
  end
end
