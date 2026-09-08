defmodule OptimalSystemAgent.Agents.RegistryDedupTest do
  @moduledoc """
  Regression test — `list_agents` (backed by `Registry.list/0`) must never show
  the same agent twice.

  `definitions/0` is a map keyed by the declared `name`, so a byte-identical
  repeat can never survive a reload: later writes to the same key replace the
  earlier value. The gap: two sources — say the built-in catalog and a project
  `.claude/agents` directory admitted mid-session by `/trust accept` — can
  declare the SAME conceptual agent under names that are not byte-identical (a
  stray trailing space, a different case). Those never collide as map keys, so
  a "first call" (before the second source is admitted) sees one row, and a
  "resume" (after it is) sees two rows for what the model reasonably reads as
  one agent.

  Runs `async: false` and pokes the module's own `:persistent_term` key
  directly (mirroring exactly what `load/0` writes) rather than going through
  `load/0` itself, so it exercises `list/0` in isolation from the real
  filesystem's built-in/user agent directories and cannot race the `async:
  true` tests in `registry_test.exs` that read the live roster.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agents.Registry

  @persistent_key {OptimalSystemAgent.Agents.Registry, :definitions}

  setup do
    previous = :persistent_term.get(@persistent_key, %{})
    on_exit(fn -> :persistent_term.put(@persistent_key, previous) end)
    :ok
  end

  defp tmp_dir do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    dir = Path.join(System.tmp_dir!(), "osa_agent_registry_dedup_#{suffix}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_agent(dir, filename, name) do
    File.write!(Path.join(dir, filename), """
    ---
    name: #{name}
    description: test agent
    ---
    Body.
    """)
  end

  test "a source admitted after the first call never doubles an existing agent" do
    built_in = tmp_dir()
    write_agent(built_in, "explorer.md", "explorer")

    # First call: only the built-in source is loaded (the pre-trust state).
    first_call = Registry.load_from_paths([{:built_in, built_in}])
    :persistent_term.put(@persistent_key, first_call)

    assert [%{name: "explorer"}] = Registry.list()

    # "Resume": a project directory is now admitted too, declaring the SAME
    # agent under a name that is not byte-identical — a trailing space and a
    # different case, exactly the kind of drift a hand-edited AGENT.md invites.
    project = tmp_dir()
    write_agent(project, "explorer.md", "Explorer ")

    resumed = Registry.load_from_paths([{:built_in, built_in}, {:project_osa, project}])
    :persistent_term.put(@persistent_key, resumed)

    # The raw map genuinely holds two keys — "explorer" and "Explorer " never
    # collided as map keys, so load_from_paths cannot be expected to merge
    # them. list/0 is the guarantee.
    assert map_size(resumed) == 2

    listed = Registry.list()

    names = Enum.map(listed, & &1.name)
    assert length(listed) == 1, "list/0 returned a duplicate: #{inspect(names)}"

    normalized = Enum.map(listed, &(&1.name |> String.trim() |> String.downcase()))
    assert normalized == Enum.uniq(normalized)
  end

  test "distinct agents with unrelated names are never collapsed" do
    dir = tmp_dir()
    write_agent(dir, "explorer.md", "explorer")
    write_agent(dir, "architect.md", "architect")

    :persistent_term.put(@persistent_key, Registry.load_from_paths([{:built_in, dir}]))

    assert Registry.list() |> Enum.map(& &1.name) |> Enum.sort() == ["architect", "explorer"]
  end
end
