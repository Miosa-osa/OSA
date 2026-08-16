defmodule OptimalSystemAgent.Tools.InstructionPlacementTest do
  @moduledoc """
  Where each rule is stated, and that it is stated exactly once.

  ## The finding this encodes

  Codex's entire `shell_command` description is ~150 bytes and `apply_patch`'s
  is 118; mini-swe-agent's is 22. Their *total* instruction is not smaller than
  ours — codex ships 20.7 KB of it. It is **placed** differently: policy in the
  system prompt, stated once; the parameter contract in the parameter
  descriptions, next to the schema it constrains; and in the tool description,
  only the one thing a model reliably gets wrong about that tool.

  OSA put all three kinds in the description and paid for the overlap on every
  request of every turn. The same "never re-read after a successful edit" rule
  was stated in five tool descriptions and twice more in `SYSTEM.md`.

  So this file asserts placement, not presence:

    * a **policy** rule appears in both system prompts and in **zero** tool
      descriptions — a policy restated per-tool is a policy bought N times;
    * a **parameter contract** appears in its parameter's description;
    * the system prompts stay a superset of what was relocated out of the
      descriptions, so a future trim of `SYSTEM.md` cannot silently drop a rule
      that no longer has a second home.

  A test that pins a rule to a *string* is what blocks the next relocation.
  These pin it to a *surface*, which is the thing that actually has to hold.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Registry

  setup_all do
    # The registry registers builtins asynchronously at boot; asking before it
    # settles reports a short array and silently passes every "zero tools"
    # assertion below for the wrong reason.
    active =
      Enum.reduce_while(1..40, [], fn _, _ ->
        case Registry.list_active() do
          tools when length(tools) >= 20 -> {:halt, tools}
          _ -> Process.sleep(100) && {:cont, []}
        end
      end)

    assert length(active) >= 20,
           "registry never settled; the placement assertions would pass vacuously"

    {:ok,
     active: active,
     system: File.read!("priv/prompts/SYSTEM.md"),
     lean: File.read!("priv/prompts/SYSTEM_LEAN.md")}
  end

  # Rules classified as POLICY: true of the whole session, not of one tool.
  # `{label, needle_in_SYSTEM.md, needle_in_SYSTEM_LEAN.md, needles_that_must_not_appear_in_any_description}`
  @policies [
    {"never re-read after a successful edit", "Never re-read after a successful edit",
     "Never re-read after a successful edit", ["Do NOT re-read", "do NOT re-read"]},
    {"read before you edit, with the file_transform carve-out",
     "`file_transform` needs no prior read", "`file_transform` needs no read",
     ["this tool errors otherwise"]},
    {"shell mutation of files is refused", "sed -i", "sed -i", ["sed -i"]},
    {"batch independent calls", "DEFAULT TO PARALLEL", "Batch independent calls",
     ["in parallel in one turn", "as parallel calls"]},
    {"no unrequested emojis or doc files", "Never write into a file what nobody asked for",
     "Never write into a file what nobody asked for", ["Only use emojis", "NEVER create"]},
    {"answer a question about a file with a program", "Answer With a Program, Not With a Read",
     "Answer with a program, not with a read", ["ANSWER A QUESTION about a file"]},
    {"git commit hygiene", "Git Safety", "Git Safety", ["Git Safety Protocol"]}
  ]

  describe "policy is stated once, in the system prompt" do
    for {label, sys_needle, lean_needle, banned} <- @policies do
      test "#{label} is carried by both system prompts", ctx do
        assert ctx.system =~ unquote(sys_needle),
               "SYSTEM.md lost the policy: #{unquote(label)}"

        assert ctx.lean =~ unquote(lean_needle),
               "SYSTEM_LEAN.md lost the policy: #{unquote(label)}"
      end

      test "#{label} is not restated in any tool description", ctx do
        for needle <- unquote(banned) do
          offenders =
            ctx.active
            |> Enum.filter(&String.contains?(&1.description(), needle))
            |> Enum.map(& &1.name())

          assert offenders == [],
                 "#{unquote(label)} is policy and belongs in the system prompt only, " <>
                   "but #{inspect(offenders)} restate #{inspect(needle)} in their " <>
                   "description. Every request of every turn pays for each copy."
        end
      end
    end
  end

  # Rules classified as PARAMETER CONTRACT: they constrain one value, so they
  # live on that value's schema entry. Losing one is a behaviour change.
  @contracts [
    {"shell_execute", "command", "approved or refused AS A WHOLE"},
    {"shell_execute", "command", "never be saved as an always-allow rule"},
    {"shell_execute", "run_in_background", "killed when the session ends"},
    {"bash_output", "wait_ms", "DO NOT SPIN"},
    {"task_write", "action", "EXACTLY ONE task may be `in_progress`"},
    {"delegate", "task", "NOT seen this conversation"},
    {"delegate", "background", "BLOCKS you and the user"},
    {"file_edit", "old_string", "errors otherwise"},
    {"file_edit", "replace_all", "refused on a fuzzy one"},
    {"file_write", "path", "MUST read it first"},
    {"file_read", "offset", "overlapping slices"},
    {"file_transform", "expect", "requires at least one"},
    {"git", "command", "ONE bare git subcommand"},
    {"git", "args", "never `git add .`"}
  ]

  describe "a parameter contract lives on its parameter" do
    for {tool, param, needle} <- @contracts do
      test "#{tool}.#{param} states #{inspect(needle)}", ctx do
        mod = Enum.find(ctx.active, &(&1.name() == unquote(tool)))
        assert mod, "#{unquote(tool)} is not in the active array"

        described = find_param_description(mod.parameters(), unquote(param))

        assert is_binary(described),
               "#{unquote(tool)}.#{unquote(param)} has no description to carry its contract"

        assert described =~ unquote(needle),
               "#{unquote(tool)}.#{unquote(param)} lost its contract: #{unquote(needle)}"
      end
    end
  end

  # `file_transform` nests its per-operation parameters under
  # `operations.items.properties`, so the lookup has to descend rather than
  # assume every parameter is top-level.
  defp find_param_description(%{"properties" => props} = _schema, param) do
    case props do
      %{^param => %{"description" => d}} when is_binary(d) -> d
      _ -> props |> Map.values() |> Enum.find_value(&find_param_description(&1, param))
    end
  end

  defp find_param_description(%{"items" => items}, param),
    do: find_param_description(items, param)

  defp find_param_description(_, _), do: nil

  describe "the array stays mostly schema" do
    # Measured: prose was 62% of a 32,942-byte array (8,236 tok) before the
    # relocation and 38% of a 29,809-byte array (7,453 tok) after, with no rule
    # dropped. Prose creeps back a sentence at a time; a share ceiling catches
    # that in a way a byte ceiling does not, because it stays meaningful as the
    # tool count changes.
    test "description prose is under half the advertised array", ctx do
      total = ctx.active |> Enum.map(&byte_size(Jason.encode!(&1.parameters()))) |> Enum.sum()
      prose = ctx.active |> Enum.map(&byte_size(&1.description())) |> Enum.sum()
      share = prose * 100 / (total + prose)

      assert share < 45,
             "tool description prose is back up to #{Float.round(share, 1)}% of the array. " <>
               "Classify the new text: policy -> SYSTEM.md, parameter contract -> the " <>
               "parameter, and only the thing models get wrong stays in the description."
    end
  end
end
