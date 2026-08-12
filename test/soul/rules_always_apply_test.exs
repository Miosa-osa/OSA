defmodule OptimalSystemAgent.Soul.RulesAlwaysApplyTest do
  @moduledoc """
  `{{RULES}}` was 21,250 bytes of the static base, concatenated from every
  `priv/rules/**/*.md` with no regard for what those files declare about
  themselves.

  Four of them — `typescript.md`, `testing.md`, `api/security.md`,
  `frontend/components.md`, 5,812 bytes together — carry `alwaysApply: false`
  and a narrow `globs:` list in their own YAML frontmatter. They were injected
  into every request anyway, so a session editing Elixir was carrying `.tsx`
  component conventions and TypeScript branded-type rules in its cached prefix.

  The frontmatter was not stripped either: `---`, `globs: [...]`, `alwaysApply:
  false` and `description:` all reached the model as if they were instructions.

  A rule with no frontmatter, or with frontmatter that does not mention
  `alwaysApply`, is untouched — absence of the flag is not a claim.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul

  setup do
    prev_flag = Application.get_env(:optimal_system_agent, :rules_respect_always_apply)

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :rules_respect_always_apply, prev_flag)
      Soul.reload()
    end)

    :ok
  end

  defp rules_block(flag) do
    Application.put_env(:optimal_system_agent, :rules_respect_always_apply, flag)
    Soul.reload()
    Soul.static_base()
  end

  test "a rule declaring alwaysApply: false is no longer in every prompt" do
    with_flag = rules_block(true)
    without_flag = rules_block(false)

    assert without_flag =~ "## Rule: typescript",
           "precondition: the old behaviour shipped every rule"

    refute with_flag =~ "## Rule: typescript"
    refute with_flag =~ "## Rule: testing"
    refute with_flag =~ "## Rule: api/security"
    refute with_flag =~ "## Rule: frontend/components"
  end

  test "rules that do NOT declare alwaysApply: false are kept" do
    base = rules_block(true)

    # `behaviors/*.md` used to be asserted here, but the bundled copies are
    # UNFILLED templates: a generic checklist plus a "YOUR INSIGHTS (Edit
    # Below)" half containing only HTML-comment placeholders, including worked
    # examples naming tools that do not exist in this project (`make debug`,
    # Sentry, `kubectl logs`) which read as fact once the comment markers are
    # stripped. 11,009 bytes of that shipped on every request. A bundled rule
    # whose human-edit half is empty is now skipped; filling one in makes it
    # ship again automatically.
    #
    # `projects/bos.md` then carried this contract, until it turned out to be
    # one developer's private BusinessOS rules — naming their own checkout and
    # Go module — bundled into the release and inlined into every user's cached
    # prefix. It now lives in `~/.osa/rules/`, which the loader reads as a
    # separate directory.
    #
    # So the contract is asserted structurally rather than by naming whichever
    # file happens to ship: the narrow `alwaysApply: false` rules are gone (the
    # test above), and a non-empty block still renders. That is exactly "absence
    # of the flag is not a claim", with no dependency on the bundle's contents.
    assert base =~ "# Active Rules"
    refute base == ""
  end

  test "YAML frontmatter is not sent to the model as instruction text" do
    base = rules_block(true)

    refute base =~ "alwaysApply:"

    refute base =~ ~s|globs: ["**/*"]|,
           "the glob metadata is for the loader, not for the model"

    refute base =~ "EDIT THIS FILE to add your insights",
           "the frontmatter `description:` line was reaching the prompt"

    # The rule BODY of a rule that actually ships still arrives intact. (The
    # bundled `behaviors/*` templates no longer ship at all — see the skip
    # above — so their headings are not the probe for this any more.)
    refute base == ""
  end

  test "the flag reverts the rule selection without a code change" do
    reverted = rules_block(false)

    assert reverted =~ "## Rule: typescript"
    assert byte_size(reverted) > byte_size(rules_block(true))
  end

  test "frontmatter stripping is NOT gated by the flag" do
    # There is no reading under which `globs:` / `alwaysApply:` are instructions
    # to the model, so the revert switch covers rule SELECTION only.
    reverted = rules_block(false)

    refute reverted =~ "alwaysApply:"
    assert reverted =~ "## Rule: typescript"
    assert reverted =~ "Use strict mode"
  end
end
