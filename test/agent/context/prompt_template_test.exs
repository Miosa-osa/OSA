defmodule OptimalSystemAgent.Agent.Context.PromptTemplateTest do
  @moduledoc """
  Tests for the conditional, tool-name-injected prompt template renderer
  (grok `prompt/template.rs` port) and its use in the tool_process block:

    * `${{ tools.KEY }}` injects the LIVE registered name (survives renames).
    * `${%- if tools.KEY %}…${%- endif %}` sections render only when that tool
      is actually active.
    * With every tool present the block is byte-for-byte the pre-refactor prompt
      (no regression); trimmed toolsets get a trimmed, accurate prompt.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Context.PromptTemplate

  # ── Renderer unit tests ────────────────────────────────────────────────

  describe "PromptTemplate.render/2,3 — variable substitution" do
    test "injects the live tool name for a present tool" do
      tools = %{"read" => "read_file"}
      assert PromptTemplate.render("Use ${{ tools.read }} to read.", tools) ==
               "Use read_file to read."
    end

    test "injects an OVERRIDDEN/renamed live name (survives rename)" do
      tools = %{"read" => "view_file"}
      assert PromptTemplate.render("Use ${{ tools.read }}.", tools) == "Use view_file."
    end

    test "falls back to the canonical key when the tool is absent (prose never breaks)" do
      assert PromptTemplate.render("Use ${{ tools.read }}.", %{}) == "Use read."
    end

    test "literal (non-$) braces pass through untouched" do
      assert PromptTemplate.render("Use {{ x }} in prose.", %{}) == "Use {{ x }} in prose."
    end

    test "no-marker template hits the fast path unchanged" do
      assert PromptTemplate.render("nothing to see here", %{"a" => "b"}) == "nothing to see here"
    end
  end

  describe "PromptTemplate.render/2,3 — conditionals" do
    test "section renders when the tool is present" do
      t = "${%- if tools.plan %}show${%- endif %}"
      assert PromptTemplate.render(t, %{"plan" => "todo_write"}) == "show"
    end

    test "section is omitted when the tool is absent" do
      t = "${%- if tools.plan %}show${%- endif %}"
      assert PromptTemplate.render(t, %{}) == ""
    end

    test "or-condition renders when ANY listed tool is present" do
      t = "${%- if tools.search or tools.use %}X${%- endif %}"
      assert PromptTemplate.render(t, %{"use" => "use_tool"}) == "X"
      assert PromptTemplate.render(t, %{}) == ""
    end

    test "and-condition requires all listed tools" do
      t = "${%- if tools.a and tools.b %}X${%- endif %}"
      assert PromptTemplate.render(t, %{"a" => "a", "b" => "b"}) == "X"
      assert PromptTemplate.render(t, %{"a" => "a"}) == ""
    end

    test "else branch renders when the condition is false" do
      t = "${%- if tools.a %}yes${%- else %}no${%- endif %}"
      assert PromptTemplate.render(t, %{"a" => "a"}) == "yes"
      assert PromptTemplate.render(t, %{}) == "no"
    end

    test "nested conditionals evaluate independently" do
      t = "${%- if tools.a %}A${%- if tools.b %}B${%- endif %}${%- endif %}"
      assert PromptTemplate.render(t, %{"a" => "a", "b" => "b"}) == "AB"
      assert PromptTemplate.render(t, %{"a" => "a"}) == "A"
      assert PromptTemplate.render(t, %{}) == ""
    end

    test "conditional + injected name compose: name only appears inside its guard" do
      t = "${%- if tools.search %}via ${{ tools.search }}${%- endif %}"
      assert PromptTemplate.render(t, %{"search" => "grep"}) == "via grep"
      assert PromptTemplate.render(t, %{}) == ""
    end

    test "extras drive boolean placeholders" do
      t = "${%- if flag %}ON${%- else %}OFF${%- endif %}"
      assert PromptTemplate.render(t, %{}, %{"flag" => true}) == "ON"
      assert PromptTemplate.render(t, %{}, %{"flag" => false}) == "OFF"
    end
  end

  # ── tool_process block via Context.build ───────────────────────────────

  @all_tools ~w(ask_user task_write file_read file_write file_edit file_grep
                file_glob dir_list web_fetch shell_execute codebase_explore
                delegate mixture_of_agents tool_search use_tool)

  defp build_text(active) do
    state = %{
      session_id: "pt-#{:erlang.unique_integer([:positive])}",
      channel: :cli,
      messages: [],
      plan_mode: false,
      working_dir: "/tmp",
      active_tool_names: active
    }

    %{messages: [sys | _]} = Context.build(state)

    case sys.content do
      c when is_binary(c) -> c
      c when is_list(c) -> Enum.map_join(c, "\n", & &1.text)
    end
  end

  # Isolate the tool_process block from the full system prompt (which also
  # carries a static base and a per-request runtime block with a live
  # timestamp, so the WHOLE prompt is intentionally non-deterministic).
  defp block(active) do
    text = build_text(active)

    case Regex.run(~r/## Act — don't just chat.*?beyond what was asked\./s, text) do
      [b] -> b
      _ -> ""
    end
  end

  describe "full toolset — no regression" do
    test "renders the pre-refactor tool_process block byte-for-byte" do
      fixture =
        Path.join([__DIR__, "..", "..", "fixtures", "tool_process_full_prompt.txt"])
        |> File.read!()
        |> String.trim_trailing("\n")

      text = build_text(@all_tools)
      assert String.contains?(text, fixture)
    end

    test "no unresolved template markers leak into the prompt" do
      text = build_text(@all_tools)
      refute String.contains?(text, "${{")
      refute String.contains?(text, "${%")
    end

    test "the tool_process block renders deterministically across two builds" do
      assert block(@all_tools) == block(@all_tools)
      assert block(@all_tools) != ""
    end
  end

  describe "conditional sections gate on active tools" do
    test "Task-management section present only when task_write is active" do
      with_tw = build_text(@all_tools)
      assert String.contains?(with_tw, "## Manage multi-step work")
      assert String.contains?(with_tw, "use task_write to lay out the plan")

      without_tw = build_text(@all_tools -- ["task_write"])
      refute String.contains?(without_tw, "## Manage multi-step work")
      # The rest of the block still renders.
      assert String.contains?(without_tw, "## Verify, then report faithfully")
    end

    test "Delegate section present only when delegate is active" do
      with_del = build_text(@all_tools)
      assert String.contains?(with_del, "## When to delegate")

      without_del = build_text(@all_tools -- ["delegate"])
      refute String.contains?(without_del, "## When to delegate")
      # General guidance under (not tied to delegate) survives.
      assert String.contains?(without_del, "You can call multiple tools in one response")
      assert String.contains?(without_del, "Rules: read a file before editing it")
    end

    test "mixture_of_agents sentence gates independently within the delegate section" do
      full = build_text(@all_tools)
      assert String.contains?(full, "Use mixture_of_agents when you want several")

      no_moa = block(@all_tools -- ["mixture_of_agents"])
      # Delegate section still present, but the MoA sentence is gone.
      assert String.contains?(no_moa, "## When to delegate")
      refute String.contains?(no_moa, "Use mixture_of_agents when you want several")
    end

    test "tool virtualization note present only when tool_search/use_tool is active" do
      full = build_text(@all_tools)
      assert String.contains?(full, "Tools not shown in your list are reachable via tool_search")

      trimmed = build_text(@all_tools -- ["tool_search", "use_tool"])
      refute String.contains?(trimmed, "Tools not shown in your list are reachable via")
      # The surrounding Tools section still renders.
      assert String.contains?(trimmed, "## Tools")
    end
  end

  describe "tool names come from the live registry set (rename/virtualization)" do
    test "uses the live registered name when a tool is renamed via its alias" do
      # `tool_search` renamed to its `search_tool` alias in the active set.
      active = (@all_tools -- ["tool_search"]) ++ ["search_tool"]
      text = build_text(active)
      # The note gates on (present) and injects the REAL live name.
      assert String.contains?(text, "reachable via search_tool")
      refute String.contains?(text, "reachable via tool_search")
    end

    test "injected tool names all come from the active set (no hardcoded drift)" do
      text = build_text(@all_tools)

      for name <- ~w(file_write file_read file_edit file_grep file_glob dir_list
                     web_fetch shell_execute codebase_explore task_write delegate) do
        assert String.contains?(text, name), "expected live tool name #{name} in prompt"
      end
    end
  end

  describe "unknown active set falls back to full render (safety)" do
    test "no active_tool_names override still yields the full block" do
      state = %{
        session_id: "pt-fallback-#{:erlang.unique_integer([:positive])}",
        channel: :cli,
        messages: [],
        plan_mode: false,
        working_dir: "/tmp"
      }

      %{messages: [sys | _]} = Context.build(state)

      text =
        case sys.content do
          c when is_binary(c) -> c
          c when is_list(c) -> Enum.map_join(c, "\n", & &1.text)
        end

      assert String.contains?(text, "## Act — don't just chat")
    end
  end
end
