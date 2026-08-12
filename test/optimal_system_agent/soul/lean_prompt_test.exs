defmodule OptimalSystemAgent.Soul.LeanPromptTest do
  @moduledoc """
  Pins the `:lean_prompt` cut.

  The lean template exists because the static prefix, not the model, was the
  thing OSA could still make smaller: `:native_tools` measured 16,059 tokens
  against opencode's ~2.1k base prompt. The cut is safe only for as long as it
  keeps cutting DUPLICATION rather than guidance, so these tests assert both
  halves — that the flag actually shrinks the prompt, and that the instructions
  which exist in exactly one place survive it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul

  setup do
    original = Application.get_env(:optimal_system_agent, :lean_prompt)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:optimal_system_agent, :lean_prompt)
      else
        Application.put_env(:optimal_system_agent, :lean_prompt, original)
      end

      Soul.invalidate_static_base()
    end)

    :ok
  end

  defp with_flag(value, fun) do
    Application.put_env(:optimal_system_agent, :lean_prompt, value)
    Soul.invalidate_static_base()
    result = fun.(Soul.static_base(:native_tools))
    Soul.invalidate_static_base()
    result
  end

  test "the flag is on by default" do
    Application.delete_env(:optimal_system_agent, :lean_prompt)
    assert Soul.lean_prompt?()
  end

  test "turning the flag off restores the long template" do
    lean = with_flag(true, & &1)
    long = with_flag(false, & &1)

    assert byte_size(lean) < byte_size(long),
           "lean base is #{byte_size(lean)} B, long is #{byte_size(long)} B — " <>
             "the flag is not switching templates"

    # The cut is worth having at all only if it is substantial.
    assert byte_size(long) - byte_size(lean) > 15_000
  end

  test "lean keeps every instruction that exists in exactly one place" do
    base = with_flag(true, & &1)

    # Each of these is guidance no tool schema and no other section carries.
    for phrase <- [
          # completion audit
          "Treat completion as",
          "Match the verification's scope to the requirement's scope",
          # permission-mode validation matrix
          "overdrive",
          "accept-edits",
          # never-guess coding standards
          "NEVER assume a library exists",
          "generateDateString",
          # dirty-worktree git safety
          "NEVER revert changes you did not make",
          "STOP IMMEDIATELY",
          # terminal formatting contract
          "Flat only — never nest bullets",
          "Never a line range",
          # execution enforcement
          "DO IT in the same turn",
          # skills are mandatory
          "MANDATORY",
          # subagent self-reports
          "SELF-REPORTS"
        ] do
      assert String.contains?(base, phrase),
             "lean template dropped #{inspect(phrase)} — that instruction has no " <>
               "other home, so this is a capability cut, not a duplication cut"
    end
  end

  test "lean drops the prose that a tool schema already carries" do
    base = with_flag(true, & &1)

    # `shell_execute` ships its own routing list on every request.
    refute String.contains?(base, "**file_read** — not shell_execute with cat")
    # the `delegate` schema ships its own parameter docs
    refute String.contains?(base, "`tier` (optional): \"elite\" (strongest model)")
    # `task_write` ships its own state machine and display format
    refute String.contains?(base, "Mark each task `completed` AFTER it's done")
  end

  test "lean drops UI affordances the model cannot act on" do
    base = with_flag(true, & &1)

    refute String.contains?(base, "/effort")
    refute String.contains?(base, "max_budget_usd")
    refute String.contains?(base, "Allow always")
    refute String.contains?(base, "/coordinator")
  end

  test "both templates expose the same interpolation points" do
    priv = :code.priv_dir(:optimal_system_agent) |> to_string()
    long = File.read!(Path.join(priv, "prompts/SYSTEM.md"))
    lean = File.read!(Path.join(priv, "prompts/SYSTEM_LEAN.md"))

    markers =
      ~w({{TOOL_DEFINITIONS}} {{RULES}} {{USER_PROFILE}} {{SOUL_CONTENT}} {{IDENTITY_PROFILE}})

    for m <- markers do
      assert String.contains?(long, m)

      assert String.contains?(lean, m),
             "SYSTEM_LEAN.md is missing #{m} — Soul interpolates both templates " <>
               "through the same path, so a missing marker silently drops that content"
    end
  end

  test "unfilled bundled rule templates stay out of the prompt" do
    base = with_flag(true, & &1)

    # priv/rules/behaviors/*.md are shipped with their human-edit half empty.
    refute String.contains?(base, "HUMAN EDIT SECTION"),
           "an unfilled rule template reached the model"

    refute String.contains?(base, "Add patterns you've noticed")
  end

  test "a rule with real content still ships" do
    base = with_flag(true, & &1)

    # projects/bos.md carries no template marker and real instructions.
    assert String.contains?(base, "# Active Rules")

    assert String.contains?(base, "slog"),
           "the rules mechanism itself broke — a filled rule stopped being injected"
  end

  test "HTML comments never reach the model, flag or no flag" do
    # Same argument as frontmatter stripping: a comment is invisible in a
    # rendered doc, so the worked examples inside these files (`make debug`,
    # Sentry, `kubectl logs` — none of which exist here) were being shipped as
    # instruction text by accident, never by intent.
    for flag <- [true, false] do
      base = with_flag(flag, & &1)
      refute String.contains?(base, "<!--"), "raw HTML comment in prompt (lean=#{flag})"
    end
  end
end
