defmodule MiosaMemory.TaxonomyShimTest do
  @moduledoc """
  Memory scope decides which entries get injected into a prompt.

  The previous implementation defined `valid_category?(_) -> true`,
  `valid_scope?(_) -> true` and `filter_by(entries, _filters) -> entries`, so
  validation passed unconditionally and scope filtering was a no-op that
  returned the UNFILTERED set — a filter that silently widens, reading at the
  call site as though it had run.

  Worse, the branch was chosen by `Code.ensure_loaded?/1` in a MODULE BODY,
  which Elixir evaluates at compile time and freezes into the BEAM file, so
  implementing the target module later could never take effect and nothing
  forced the recompile that would notice.
  """

  use ExUnit.Case, async: true

  alias MiosaMemory.Taxonomy

  describe "validation fails CLOSED" do
    test "a category outside the vocabulary is invalid" do
      assert Taxonomy.valid_category?("decision")
      refute Taxonomy.valid_category?("not-a-category")
      refute Taxonomy.valid_category?(nil)
      refute Taxonomy.valid_category?(%{})
      refute Taxonomy.valid_category?(""), "the empty string is not a category"
    end

    test "a scope outside the vocabulary is invalid" do
      assert Taxonomy.valid_scope?("session")
      refute Taxonomy.valid_scope?("not-a-scope")
      refute Taxonomy.valid_scope?(nil)
      refute Taxonomy.valid_scope?(123)
    end

    test "atoms and strings are accepted equivalently" do
      assert Taxonomy.valid_scope?(:session)
      assert Taxonomy.valid_category?(:decision)
    end

    test "every advertised value validates" do
      # A vocabulary whose own members fail its validator is worse than no
      # validator at all.
      for c <- Taxonomy.categories(), do: assert(Taxonomy.valid_category?(c))
      for s <- Taxonomy.scopes(), do: assert(Taxonomy.valid_scope?(s))
    end
  end

  describe "scope filtering actually filters" do
    @entries [
      %{id: 1, category: "decision", scope: "session"},
      %{id: 2, category: "decision", scope: "global"},
      %{id: 3, category: "lesson", scope: "session"},
      %{id: 4, category: "lesson", scope: "project"}
    ]

    test "filtering by scope excludes the other scopes" do
      # This is the leak: the old no-op returned all four, so a caller asking
      # for session-scoped memories got another project's entries injected
      # into its prompt.
      assert [%{id: 1}, %{id: 3}] = Taxonomy.filter_by(@entries, scope: "session")
    end

    test "filtering by category excludes the other categories" do
      assert [%{id: 1}, %{id: 2}] = Taxonomy.filter_by(@entries, category: "decision")
    end

    test "category and scope compose" do
      assert [%{id: 1}] = Taxonomy.filter_by(@entries, category: "decision", scope: "session")
    end

    test "a nil filter means 'do not constrain', not 'match nil'" do
      assert Taxonomy.filter_by(@entries, category: nil, scope: nil) == @entries
      assert Taxonomy.filter_by(@entries, %{}) == @entries
    end

    test "a filter value outside the vocabulary matches NOTHING" do
      # The caller asked to be restricted. Answering an unanswerable
      # restriction with the unrestricted set is how a scope filter becomes a
      # scope leak.
      assert Taxonomy.filter_by(@entries, scope: "no-such-scope") == []
    end

    test "entries keyed by string are matched too" do
      entries = [%{"id" => 1, "scope" => "session"}, %{"id" => 2, "scope" => "global"}]
      assert [%{"id" => 1}] = Taxonomy.filter_by(entries, scope: "session")
    end

    test "atom and string filter values are equivalent" do
      assert Taxonomy.filter_by(@entries, scope: :session) ==
               Taxonomy.filter_by(@entries, scope: "session")
    end

    test "a map of filters works the same as a keyword list" do
      assert Taxonomy.filter_by(@entries, %{scope: "session"}) ==
               Taxonomy.filter_by(@entries, scope: "session")
    end
  end

  describe "new/2 never stores an invalid category or scope" do
    test "an invalid scope falls back to the default and is recorded as rejected" do
      entry = Taxonomy.new("hello", scope: "no-such-scope")

      assert Taxonomy.valid_scope?(entry.scope),
             "an entry stored under an unknown scope is invisible to a scoped read " <>
               "and visible to an unscoped one — the wrong way round"

      assert {:scope, "no-such-scope"} in entry.rejected
    end

    test "an invalid category falls back to the default and is recorded as rejected" do
      entry = Taxonomy.new("hello", category: "nope")

      assert Taxonomy.valid_category?(entry.category)
      assert {:category, "nope"} in entry.rejected
    end

    test "valid values are kept verbatim and nothing is reported as rejected" do
      entry = Taxonomy.new("hello", category: "decision", scope: "project")

      assert entry.category == "decision"
      assert entry.scope == "project"
      assert entry.rejected == []
    end

    test "with no options at all, both fields are still valid" do
      entry = Taxonomy.new("hello")
      assert Taxonomy.valid_category?(entry.category)
      assert Taxonomy.valid_scope?(entry.scope)
    end
  end

  describe "the alias module delegates here, in one direction only" do
    test "Agent.Memory.Taxonomy produces identical answers" do
      # It is `defdelegate ... to: MiosaMemory.Taxonomy`. If this module ever
      # delegates BACK, the pair becomes an infinite mutual recursion — the
      # A->B->A loop this file's own Injector moduledoc warns about.
      alias OptimalSystemAgent.Agent.Memory.Taxonomy, as: Alias

      refute Alias.valid_scope?("no-such-scope")
      assert Alias.valid_scope?("session")
      assert Alias.categories() == Taxonomy.categories()
    end
  end
end
