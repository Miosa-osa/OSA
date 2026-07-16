defmodule OptimalSystemAgent.Agent.Loop.ToolFilterTest do
  use ExUnit.Case, async: false

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
