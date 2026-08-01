defmodule OptimalSystemAgent.Agent.Loop.ToolHintTest do
  @moduledoc """
  The tool-cell argument summary. Three user-visible failures came out of the
  old inline version and each has a test here:

    * `ask_user` rendered as `"options, question"` — the SCHEMA's parameter
      names presented as if they were the question;
    * file edits rendered as a raw JSON dump of their whole argument map, so
      the cell never named the file it was editing;
    * `task_write` rendered as the bare verb `"add"`, so the operator could not
      see WHICH task had been created.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.ToolHint

  describe "never leaks schema parameter names" do
    test "ask_user shows the question, not \"options, question\"" do
      hint =
        ToolHint.summarize(%{
          "question" => "Which parser should we keep?",
          "options" => ["Rewrite", "Patch"]
        })

      assert hint == "Which parser should we keep?"
      refute hint =~ "options"
    end

    test "delegate shows the teammate name, not \"name, role\"" do
      assert ToolHint.summarize(%{"name" => "smoke-e2e", "role" => "tester"}) == "smoke-e2e"
    end

    test "an unknown multi-argument tool emits nothing rather than key names" do
      hint = ToolHint.summarize(%{"alpha" => "a", "beta" => "b", "gamma" => "c"})
      assert hint == ""
      refute hint =~ "alpha"
    end

    test "an unknown single-scalar tool shows that one value" do
      assert ToolHint.summarize(%{"some_unknown_key" => "the-value"}) == "the-value"
    end

    test "empty and non-map arguments summarize to nothing" do
      assert ToolHint.summarize(%{}) == ""
      assert ToolHint.summarize(nil) == ""
      assert ToolHint.summarize("not a map") == ""
    end
  end

  describe "file tools identify the file" do
    test "a path-carrying call summarizes to the path" do
      assert ToolHint.summarize(%{"path" => "/src/main.rs"}) == "/src/main.rs"
      assert ToolHint.summarize(%{"file_path" => "/src/main.rs"}) == "/src/main.rs"
      assert ToolHint.summarize(%{"notebook_path" => "/nb.ipynb"}) == "/nb.ipynb"
    end

    test "a path is never truncated — the whole path goes on the wire" do
      path = "/a/very/long/absolute/path/that/exceeds/sixty/characters/in/total/main.rs"
      assert ToolHint.summarize(%{"path" => path}) == path
    end

    test "file_edit still ships JSON (the TUI renders a diff from it) and it CONTAINS the path" do
      hint =
        ToolHint.summarize(%{
          "path" => "/src/main.rs",
          "old_string" => "a",
          "new_string" => "b"
        })

      assert {:ok, decoded} = Jason.decode(hint)
      assert decoded["path"] == "/src/main.rs"
      assert decoded["old_string"] == "a"
      assert decoded["new_string"] == "b"
    end
  end

  describe "task_write carries the task titles" do
    test "add shows the title, not the verb" do
      hint = ToolHint.summarize(%{"action" => "add", "title" => "Refactor the parser"})
      assert hint == "Refactor the parser"
      refute hint == "add"
    end

    test "add_multiple shows the first title plus a count" do
      hint =
        ToolHint.summarize(%{
          "action" => "add_multiple",
          "titles" => ["Refactor the parser", "Add tests", "Update docs"]
        })

      assert hint =~ "Refactor the parser"
      assert hint =~ "+2 more"
    end

    test "add_multiple with a single title omits the counter" do
      hint = ToolHint.summarize(%{"action" => "add_multiple", "titles" => ["Only one"]})
      assert hint == "Only one"
    end

    test "a status change names the task and the new state" do
      assert ToolHint.summarize(%{"action" => "complete", "task_id" => "t-7"}) == "complete t-7"

      assert ToolHint.summarize(%{"action" => "start", "title" => "Refactor the parser"}) ==
               "start Refactor the parser"
    end

    test "an action with nothing to name falls back to the action" do
      assert ToolHint.summarize(%{"action" => "list"}) == "list"
    end
  end

  describe "other tools keep their existing summaries" do
    test "shell shows the command" do
      assert ToolHint.summarize(%{"command" => "cargo test --release"}) ==
               "cargo test --release"
    end

    test "a long command is clipped to 60 characters" do
      assert ToolHint.summarize(%{"command" => String.duplicate("a", 80)})
             |> String.length() == 60
    end

    test "search shows the pattern or the query" do
      assert ToolHint.summarize(%{"pattern" => "TODO"}) == "TODO"
      assert ToolHint.summarize(%{"query" => "dead code"}) == "dead code"
    end

    test "computer_use actions keep their coordinate summaries" do
      assert ToolHint.summarize(%{"action" => "screenshot"}) == "screenshot"
      assert ToolHint.summarize(%{"action" => "click", "x" => 3, "y" => 4}) == "click (3, 4)"
    end

    test "use_skill shows the skill name" do
      assert ToolHint.summarize(%{"skill_name" => "pdf-fill"}) == "pdf-fill"
    end
  end
end
