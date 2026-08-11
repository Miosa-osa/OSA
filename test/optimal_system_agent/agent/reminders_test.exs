defmodule OptimalSystemAgent.Agent.RemindersTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Reminders
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Shell.BackgroundManager

  # Unique session id per test so the per-session claimed set never bleeds
  # across cases (and BackgroundManager.list/RunStore.list filtering isolates).
  # The session id doubles as an on-disk scratch dir (`<tmp>/osa/<session>`),
  # so remove it on exit instead of leaving residue behind in /tmp.
  defp sid do
    id = "rem-test-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
    on_exit(fn -> File.rm_rf(Path.join([System.tmp_dir!(), "osa", id])) end)
    id
  end

  describe "format_with_reminders/2" do
    test "returns output unchanged when there are no reminders" do
      assert Reminders.format_with_reminders("tool output", []) == "tool output"
    end

    test "wraps each reminder in <system-reminder> tags and appends" do
      out = Reminders.format_with_reminders("tool output", ["one", "two"])

      assert String.starts_with?(out, "tool output\n\n")
      assert out =~ "<system-reminder>\none\n</system-reminder>"
      assert out =~ "<system-reminder>\ntwo\n</system-reminder>"
    end

    test "joins to empty output without a leading separator" do
      out = Reminders.format_with_reminders("", ["only"])
      assert out == "<system-reminder>\nonly\n</system-reminder>"
    end
  end

  describe "claim/2 (dedup)" do
    test "returns true the first time and false thereafter for the same key" do
      s = sid()
      assert Reminders.claim(s, {:x, "k1"}) == true
      assert Reminders.claim(s, {:x, "k1"}) == false
      # a different key in the same session is independent
      assert Reminders.claim(s, {:x, "k2"}) == true
      # the same key in a different session is independent
      assert Reminders.claim(sid(), {:x, "k1"}) == true
    end
  end

  describe "append/3 — non-fatal" do
    test "returns the result unchanged when nothing to surface" do
      tc = %{name: "web_search", arguments: %{"query" => "x"}, id: "t1"}
      state = %{session_id: sid()}
      assert Reminders.append("raw result", tc, state) == "raw result"
    end

    test "never raises on a malformed tool_call / state" do
      assert Reminders.append("raw", %{}, %{}) == "raw"
      assert Reminders.append("raw", %{name: nil, arguments: nil}, %{session_id: nil}) == "raw"
    end
  end

  describe "skill-discovery collector" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "rem-skill-" <> Integer.to_string(:erlang.unique_integer([:positive]))
        )

      skill_dir = Path.join([tmp, ".osa", "skills", "widget-maker"])
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: widget-maker
      description: Builds widgets on demand
      ---
      # Widget Maker
      """)

      src_dir = Path.join(tmp, "src")
      File.mkdir_p!(src_dir)
      touched = Path.join(src_dir, "app.ex")
      File.write!(touched, "defmodule App do\nend\n")

      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, tmp: tmp, touched: touched}
    end

    test "surfaces a SKILL.md at an ancestor of a just-read file, once", %{
      tmp: tmp,
      touched: touched
    } do
      s = sid()
      tc = %{name: "file_read", arguments: %{"path" => touched}, id: "r1"}
      state = %{session_id: s, working_dir: tmp}

      out = Reminders.append("file contents", tc, state)

      assert out =~ "<system-reminder>"
      assert out =~ "widget-maker"
      assert out =~ "Builds widgets on demand"
      assert out =~ "SKILL.md"

      # Deduped: a second read anywhere in the same session must not repeat it.
      out2 = Reminders.append("file contents", tc, state)
      refute out2 =~ "widget-maker"
      assert out2 == "file contents"
    end

    test "does not fire for non-filesystem tools", %{tmp: tmp} do
      s = sid()
      tc = %{name: "web_search", arguments: %{"query" => "widgets"}, id: "w1"}
      state = %{session_id: s, working_dir: tmp}
      assert Reminders.append("results", tc, state) == "results"
    end

    # Regression: the ancestor walk used to climb to `/` whenever the touched
    # path was outside the workspace root (or no root was known), which is how
    # ANOTHER product's global skills — `~/.claude/skills/*/SKILL.md` — were
    # announced to the model as "a skill near a path you just accessed".
    test "never walks above the workspace root", %{tmp: tmp} do
      s = sid()
      outside = Path.join(System.tmp_dir!(), "rem-outside-#{System.unique_integer([:positive])}")
      inner = Path.join(outside, "sub")
      File.mkdir_p!(inner)
      touched = Path.join(inner, "x.ex")
      File.write!(touched, "x")
      on_exit(fn -> File.rm_rf(outside) end)

      tc = %{name: "file_read", arguments: %{"path" => touched}, id: "o1"}
      # `tmp` is the workspace; `touched` lives outside it.
      state = %{session_id: s, working_dir: tmp}

      assert Reminders.append("obs", tc, state) == "obs"
    end

    test "does not scan skills when the workspace root is unknown", %{touched: touched} do
      s = sid()
      tc = %{name: "file_read", arguments: %{"path" => touched}, id: "n1"}
      # working_dir: nil and Cwd is the OSA repo, so `touched` (under tmp) is
      # outside it — nothing may be discovered.
      state = %{session_id: s, working_dir: nil}

      refute Reminders.append("obs", tc, state) =~ "widget-maker"
    end

    test "the user's home directory is never scanned for skills" do
      home = System.user_home!()
      s = sid()
      touched = Path.join(home, "some-file-that-need-not-exist.ex")
      tc = %{name: "file_read", arguments: %{"path" => touched}, id: "h1"}
      state = %{session_id: s, working_dir: home}

      out = Reminders.append("obs", tc, state)
      refute out =~ ".claude/skills"
      refute out =~ ".osa/skills"
    end

    test "a third-party skills dir is labelled, not presented as an OSA skill" do
      s = sid()
      root = Path.join(System.tmp_dir!(), "rem-3p-#{System.unique_integer([:positive])}")
      skill_dir = Path.join([root, ".claude", "skills", "writing-great-skills"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "description: Reference for writing\n")
      src = Path.join(root, "src")
      File.mkdir_p!(src)
      touched = Path.join(src, "a.ex")
      File.write!(touched, "a")
      on_exit(fn -> File.rm_rf(root) end)

      tc = %{name: "file_read", arguments: %{"path" => touched}, id: "t3"}
      out = Reminders.append("obs", tc, %{session_id: s, working_dir: root})

      assert out =~ "writing-great-skills"
      assert out =~ "third-party .claude skill"
      assert out =~ "not an OSA skill"
    end
  end

  describe "task-completion collector — subagents (RunStore)" do
    test "surfaces a completed subagent for the parent session, once" do
      s = sid()
      agent_id = "sub-" <> Integer.to_string(:erlang.unique_integer([:positive]))

      RunStore.start_run(%{
        agent_id: agent_id,
        parent_session_id: s,
        role: "researcher",
        task: "find things"
      })

      RunStore.complete(agent_id, %{status: :completed, summary: "found 3 things"})

      tc = %{name: "file_read", arguments: %{"path" => "/nonexistent/x"}, id: "r1"}
      state = %{session_id: s}

      out = Reminders.append("obs", tc, state)

      assert out =~ "<system-reminder>"
      assert out =~ "Background subagent"
      assert out =~ "researcher"
      assert out =~ agent_id
      assert out =~ "found 3 things"

      # Deduped on the next tool call.
      out2 = Reminders.append("obs", tc, state)
      refute out2 =~ agent_id
    end

    test "ignores subagents belonging to a different parent session" do
      s = sid()
      other = sid()
      agent_id = "sub-" <> Integer.to_string(:erlang.unique_integer([:positive]))

      RunStore.start_run(%{agent_id: agent_id, parent_session_id: other, role: "x", task: "t"})
      RunStore.complete(agent_id, %{status: :completed, summary: "done"})

      tc = %{name: "web_search", arguments: %{"query" => "q"}, id: "w1"}
      assert Reminders.append("obs", tc, %{session_id: s}) == "obs"
    end
  end

  describe "task-completion collector — background shell (BackgroundManager)" do
    test "surfaces a finished background command for the session, once" do
      s = sid()
      {:ok, id} = BackgroundManager.start("echo hello-reminder", System.tmp_dir!(), session_id: s)

      # Wait for the command to reach a terminal state.
      wait_terminal(id, 50)

      tc = %{name: "file_read", arguments: %{"path" => "/nonexistent/x"}, id: "r1"}
      state = %{session_id: s}

      out = Reminders.append("obs", tc, state)

      assert out =~ "<system-reminder>"
      assert out =~ "Background command"
      assert out =~ "completed"
      assert out =~ "Do not poll"

      # Deduped on the next tool call.
      out2 = Reminders.append("obs", tc, state)
      refute out2 =~ "Background command"
    end
  end

  describe "self-correction collector (P7)" do
    test "first semantic tool failure gets a one-shot reflection nudge" do
      s = sid()
      tc = %{name: "file_edit", arguments: %{"path" => "x.ex"}, id: "e1"}

      out =
        Reminders.append("Error: old_string not found in x.ex", tc, s |> then(&%{session_id: &1}))

      assert out =~ "<system-reminder>"
      assert out =~ "Self-correction"
      assert out =~ "old_string not found"
    end

    test "a second occurrence of the identical failure signature does not repeat the nudge" do
      s = sid()
      tc = %{name: "file_edit", arguments: %{"path" => "x.ex"}, id: "e1"}
      state = %{session_id: s}
      error = "Error: old_string not found in x.ex"

      out1 = Reminders.append(error, tc, state)
      assert out1 =~ "Self-correction"

      out2 = Reminders.append(error, tc, state)
      refute out2 =~ "Self-correction"
    end

    test "a DIFFERENT failure signature (different tool/error) still gets its own nudge" do
      s = sid()
      state = %{session_id: s}

      tc1 = %{name: "file_edit", arguments: %{"path" => "x.ex"}, id: "e1"}
      out1 = Reminders.append("Error: old_string not found in x.ex", tc1, state)
      assert out1 =~ "Self-correction"

      tc2 = %{name: "file_edit", arguments: %{"path" => "y.ex"}, id: "e2"}
      out2 = Reminders.append("Error: ambiguous match — old_string found 3 times", tc2, state)
      assert out2 =~ "Self-correction"
    end

    test "a transient (non-semantic) failure gets no nudge" do
      s = sid()
      tc = %{name: "web_fetch", arguments: %{"url" => "http://x"}, id: "e1"}
      state = %{session_id: s}

      out = Reminders.append("Error: connection timeout", tc, state)
      refute out =~ "Self-correction"
    end

    test "a permission block (\"Blocked:\") gets no self-correction nudge" do
      s = sid()
      tc = %{name: "shell_execute", arguments: %{"command" => "rm -rf /"}, id: "e1"}
      state = %{session_id: s}

      out = Reminders.append("Blocked: dangerous command", tc, state)
      refute out =~ "Self-correction"
    end

    test "a successful result gets no nudge" do
      s = sid()
      tc = %{name: "file_read", arguments: %{"path" => "x.ex"}, id: "e1"}
      state = %{session_id: s}

      out = Reminders.append("file contents here", tc, state)
      refute out =~ "Self-correction"
    end
  end

  # Poll BackgroundManager.output until the task is no longer :running.
  defp wait_terminal(_id, 0), do: :timeout

  defp wait_terminal(id, retries) do
    case BackgroundManager.output(id) do
      {:ok, %{status: status}} when status in [:done, :failed, :killed] ->
        :ok

      _ ->
        Process.sleep(20)
        wait_terminal(id, retries - 1)
    end
  end
end
