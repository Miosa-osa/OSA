defmodule OptimalSystemAgent.Tools.FileReadSkillRedirectTest do
  @moduledoc """
  A guessed skill path must be answered with the real one.

  The model-facing catalogue lists skills by name and says to load them with
  `skill_view`. A caller that reaches for `file_read` instead has to invent a
  path, and skills resolve across four config directories at three scopes, so
  the invention is usually wrong. The generic reply then pointed at `dir_list`
  on a parent that does not exist either, and the caller kept guessing: one
  observed session spent eighteen reads across two wrong roots for four skills
  that were correctly registered the whole time.

  `async: false` — these swap the registry's `:persistent_term` skill table.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Messages
  alias OptimalSystemAgent.Tools.Registry

  @key {Registry, :skills}

  setup do
    previous = :persistent_term.get(@key, :none)

    :persistent_term.put(@key, %{
      "writing-beats" => %{
        name: "writing-beats",
        path: "/Users/someone/.agents/skills/writing-beats/SKILL.md"
      },
      "impeccable" => %{
        name: "impeccable",
        path: "/Users/someone/.claude/skills/impeccable/SKILL.md"
      }
    })

    on_exit(fn ->
      case previous do
        :none -> :persistent_term.erase(@key)
        v -> :persistent_term.put(@key, v)
      end
    end)

    :ok
  end

  describe "a guessed skill path" do
    test "is answered with the path the skill actually resolves to" do
      # The exact miss from the observed session: right name, wrong root.
      guess = "/Users/someone/code/proj/.claude/skills/writing-beats/SKILL.md"

      msg = Messages.missing(guess, guess)

      assert msg =~ "/Users/someone/.agents/skills/writing-beats/SKILL.md"
      assert msg =~ "skill_view"
      assert msg =~ ~s(name: "writing-beats")
    end

    test "is recognised under any config root, not just the one that was guessed" do
      for root <- ["/home/u/.osa", "/home/u/.claude", "/home/u/.codex", "/tmp/proj/.grok"] do
        guess = "#{root}/skills/impeccable/SKILL.md"
        msg = Messages.missing(guess, guess)

        assert msg =~ "/Users/someone/.claude/skills/impeccable/SKILL.md",
               "no redirect for #{guess}: #{msg}"
      end
    end

    test "matches SKILL.md case-insensitively" do
      guess = "/x/skills/impeccable/skill.md"
      assert Messages.missing(guess, guess) =~ "skill_view"
    end
  end

  describe "everything else keeps the ordinary diagnosis" do
    test "a skill-shaped path for an unregistered name does not invent a redirect" do
      guess = "/x/skills/no-such-skill/SKILL.md"
      msg = Messages.missing(guess, guess)

      refute msg =~ "skill_view"
      assert msg =~ "does not exist"
    end

    test "an ordinary missing file is untouched" do
      msg = Messages.missing("/x/nope/readme.md", "/x/nope/readme.md")

      refute msg =~ "skill_view"
      assert msg =~ "does not exist"
    end

    test "a file merely named SKILL.md outside a skills dir is not a skill" do
      # `skills/` is what makes it a skill path; without it this is just a file.
      guess = "/x/docs/writing-beats/SKILL.md"
      refute Messages.missing(guess, guess) =~ "skill_view"
    end

    test "an empty registry cannot redirect and must not crash" do
      :persistent_term.erase(@key)
      guess = "/x/skills/writing-beats/SKILL.md"

      msg = Messages.missing(guess, guess)
      refute msg =~ "skill_view"
      assert msg =~ "does not exist"
    end
  end
end
