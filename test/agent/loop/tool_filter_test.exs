defmodule OptimalSystemAgent.Agent.Loop.ToolFilterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.ToolFilter

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    previous_session = session_effort_level()
    Effort.set(:medium)

    on_exit(fn ->
      restore_session_effort_level(previous_session)

      if previous do
        Application.put_env(:optimal_system_agent, :effort_level, previous)
      else
        Application.delete_env(:optimal_system_agent, :effort_level)
      end
    end)

    :ok
  end

  test "fast mode applies an aggressive tool budget" do
    Effort.set(:low)

    tools =
      ~w(file_read file_write file_edit shell_execute ask_user computer_use memory_recall web_search git diff grep)
      |> Enum.map(&%{name: &1})

    filtered =
      ToolFilter.filter(tools, %{
        provider: :anthropic,
        messages: [%{role: "user", content: "fix this code and run tests"}]
      })

    assert length(filtered) <= Effort.tool_budget()
    names = Enum.map(filtered, & &1.name)
    assert "file_read" in names
    assert "shell_execute" in names
    assert "git" in names
  end

  test "fast mode keeps full tool list when intent is unclear" do
    Effort.set(:low)
    tools = Enum.map(1..12, &%{name: "tool_#{&1}"})

    assert ToolFilter.filter(tools, %{
             provider: :anthropic,
             messages: [%{role: "user", content: "hello"}]
           }) == tools
  end

  test "medium mode does not trim non-local providers" do
    Effort.set(:medium)
    tools = Enum.map(1..12, &%{name: "tool_#{&1}"})

    assert ToolFilter.filter(tools, %{provider: :anthropic, messages: []}) == tools
  end

  # ── Tri-mode delegation policy (primitive #34) ──────────────────────────

  describe "delegation policy tool gating" do
    defp tools_with_delegate do
      ~w(file_read shell_execute delegate create_agent)
      |> Enum.map(&%{name: &1})
    end

    test "proactive policy keeps spawning tools" do
      filtered =
        ToolFilter.filter(tools_with_delegate(), %{
          provider: :anthropic,
          messages: [],
          delegation_policy: :proactive
        })

      names = Enum.map(filtered, & &1.name)
      assert "delegate" in names
      assert "create_agent" in names
    end

    test "nil policy (config default) keeps spawning tools" do
      filtered =
        ToolFilter.filter(tools_with_delegate(), %{provider: :anthropic, messages: []})

      names = Enum.map(filtered, & &1.name)
      assert "delegate" in names
    end

    test "disabled policy strips spawning tools but keeps the rest" do
      filtered =
        ToolFilter.filter(tools_with_delegate(), %{
          provider: :anthropic,
          messages: [],
          delegation_policy: :disabled
        })

      names = Enum.map(filtered, & &1.name)
      refute "delegate" in names
      refute "create_agent" in names
      assert "file_read" in names
      assert "shell_execute" in names
    end

    test "explicit_only strips spawning tools when the user did not ask" do
      filtered =
        ToolFilter.filter(tools_with_delegate(), %{
          provider: :anthropic,
          messages: [%{role: "user", content: "fix the failing build"}],
          delegation_policy: :explicit_only
        })

      names = Enum.map(filtered, & &1.name)
      refute "delegate" in names
      assert "file_read" in names
    end

    test "explicit_only keeps spawning tools when the user asked to delegate" do
      filtered =
        ToolFilter.filter(tools_with_delegate(), %{
          provider: :anthropic,
          messages: [%{role: "user", content: "delegate this to a subagent"}],
          delegation_policy: :explicit_only
        })

      names = Enum.map(filtered, & &1.name)
      assert "delegate" in names
      assert "create_agent" in names
    end
  end

  # ── Coordinator posture (delegation/messaging only) ─────────────────────

  describe "filter_for_coordinator/2" do
    defp mixed_tools do
      ~w(delegate send_message tool_search memory_recall memory_save file_write
         shell_execute file_read web_search computer_use)
      |> Enum.map(&%{name: &1})
    end

    test "false leaves the full tool list untouched" do
      tools = mixed_tools()
      assert ToolFilter.filter_for_coordinator(tools, false) == tools
    end

    test "true keeps only the coordinator allowlist (execution tools stripped)" do
      filtered = ToolFilter.filter_for_coordinator(mixed_tools(), true)
      names = Enum.map(filtered, & &1.name)

      # Delegation / messaging / management survive.
      assert "delegate" in names
      assert "send_message" in names
      assert "memory_recall" in names
      # Execution tools are gone.
      refute "file_write" in names
      refute "shell_execute" in names
      refute "computer_use" in names
    end
  end

  # Role allowlists (explore/explorer tools_allowed) must shrink what the
  # model SEES. Execution-only gating is how a read-only explorer still
  # calls `delegate` and nests forever.
  describe "filter_for_role_allowlist/2" do
    defp advertised_tools do
      ~w(file_read file_glob file_grep dir_list code_symbols shell_execute delegate tool_search)
      |> Enum.map(&%{name: &1})
    end

    test "explore-style allowlist drops delegate and tool_search from the advertised set" do
      allowed = ~w(file_read file_glob file_grep dir_list code_symbols shell_execute)

      names =
        advertised_tools()
        |> ToolFilter.filter_for_role_allowlist(allowed)
        |> Enum.map(& &1.name)

      assert names == allowed
      refute "delegate" in names
      refute "tool_search" in names
    end

    test "nil allowlist (unrestricted / parent session) leaves the advertised set alone" do
      tools = advertised_tools()
      assert ToolFilter.filter_for_role_allowlist(tools, nil) == tools
    end

    test "empty allowlist is unrestricted, same as nil" do
      tools = advertised_tools()
      assert ToolFilter.filter_for_role_allowlist(tools, []) == tools
    end

    # The advertised set and the executable set must be ONE decision. The
    # execution gate (`ToolExecutor.subagent_tool_allowed?/2`) answers with
    # three clauses; advertising only the allowlist clause is how a subagent
    # still gets handed a tool that is then refused at call time.
    test "a denylist with no allowlist still shrinks the advertised set" do
      tools = advertised_tools()

      names =
        tools
        |> ToolFilter.filter_for_role_allowlist(%{
          allowed_tools: nil,
          blocked_tools: ["delegate", "shell_execute"],
          permission_tier: :full
        })
        |> Enum.map(& &1.name)

      refute "delegate" in names
      refute "shell_execute" in names
      assert "file_read" in names
    end

    test "at :subagent tier the always-blocked set is never advertised, allowlist or not" do
      tools = advertised_tools()

      names =
        tools
        |> ToolFilter.filter_for_role_allowlist(%{
          allowed_tools: nil,
          blocked_tools: [],
          permission_tier: :subagent
        })
        |> Enum.map(& &1.name)

      # @subagent_blocked_tools — the nest that #107 set out to stop.
      refute "delegate" in names
      assert "file_read" in names
    end

    test "advertised set agrees with the execution gate for every tool, at :subagent tier" do
      tools = advertised_tools()
      role = %{allowed_tools: ~w(file_read delegate dir_list), blocked_tools: ["dir_list"]}

      advertised =
        tools
        |> ToolFilter.filter_for_role_allowlist(Map.put(role, :permission_tier, :subagent))
        |> Enum.map(& &1.name)
        |> MapSet.new()

      executable =
        tools
        |> Enum.map(& &1.name)
        |> Enum.filter(
          &OptimalSystemAgent.Agent.Loop.ToolExecutor.subagent_tool_allowed?(&1, role)
        )
        |> MapSet.new()

      assert advertised == executable
      # and specifically: allowlisted but always-blocked, allowlisted but denied
      refute "delegate" in advertised
      refute "dir_list" in advertised
      assert "file_read" in advertised
    end

    # config/test.exs pins Logger to :warning, so an :info line is dropped
    # before capture. Raise the floor for the assertion, then put it back —
    # otherwise "does it report?" is untestable by construction.
    defp capture_info(fun) do
      previous = Logger.level()
      Logger.configure(level: :info)

      try do
        ExUnit.CaptureLog.capture_log(fun)
      after
        Logger.configure(level: previous)
      end
    end

    test "a gate that removes tools says so at info, never silently" do
      tools = advertised_tools()

      log =
        capture_info(fn ->
          ToolFilter.filter_for_role_allowlist(tools, ~w(file_read file_glob))
        end)

      assert log =~ "role tool gate active"
      assert log =~ "advertising 2 of 8 tools"
    end

    test "an unrestricted role logs nothing — the gate is inert, not quiet" do
      tools = advertised_tools()

      log = capture_info(fn -> ToolFilter.filter_for_role_allowlist(tools, nil) end)

      refute log =~ "role tool gate"
    end

    # `tools_allowed` comes from arbitrary user frontmatter. A typo or a
    # renamed tool intersects to nothing, and a zero-length schema array is not
    # something native-tool providers degrade from gracefully.
    test "an allowlist matching nothing warns loudly and does not hand over an empty array" do
      tools = advertised_tools()

      {result, log} =
        with_log(fn ->
          ToolFilter.filter_for_role_allowlist(tools, ~w(file_reed grep_search))
        end)

      assert log =~ "matches NO advertised tool"
      assert log =~ "typo"
      refute result == []
      assert length(result) == length(tools)
    end

    test "the empty-allowlist salvage still honours the denylist and the tier" do
      tools = advertised_tools()

      {result, _log} =
        with_log(fn ->
          ToolFilter.filter_for_role_allowlist(tools, %{
            allowed_tools: ~w(totally_bogus_tool),
            blocked_tools: ["file_glob"],
            permission_tier: :subagent
          })
        end)

      names = Enum.map(result, & &1.name)
      refute names == []
      refute "file_glob" in names, "denylist must survive the salvage"
      refute "delegate" in names, "always-blocked must survive the salvage"
      assert "file_read" in names
    end
  end

  defp session_effort_level do
    case :ets.whereis(:osa_settings) do
      :undefined ->
        :missing

      _ ->
        case :ets.lookup(:osa_settings, {:session, :effort_level}) do
          [{{:session, :effort_level}, value}] -> {:value, value}
          _ -> :missing
        end
    end
  end

  defp restore_session_effort_level(:missing) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.delete(:osa_settings, {:session, :effort_level})
    end
  end

  defp restore_session_effort_level({:value, value}) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.insert(:osa_settings, {{:session, :effort_level}, value})
    end
  end
end
