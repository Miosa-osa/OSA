defmodule OptimalSystemAgent.Config.RuntimePathsTest do
  @moduledoc """
  Regression guard for the "frozen home directory" bug at the CONFIG layer.

  `FrozenHomeRuntimeTest` proves that modules honour a runtime `:config_dir`
  override. This test proves the complementary half: that the app-env path keys
  themselves are DERIVED from the runtime-resolved `:config_dir` rather than
  frozen at compile time by `config/config.exs`'s `Path.expand("~/.osa/...")`.

  Those two are independent. Every module could resolve `:sessions_dir`
  perfectly and the suite would still write into the operator's real home,
  because `:sessions_dir` itself was baked to `~/.osa/sessions` while
  `:config_dir` had been re-pointed at a tmp home. That is not hypothetical:
  it is exactly how a developer box accumulated 2000+ real session files, and
  in a released build it is why a fresh install boots at the CI runner's home
  and crash-loops on `enoent` opening the sqlite file.

  Asserting this in `:test` is what makes it a live guard: the suite runs with
  `:config_dir` pointed at a per-run tmp home, so any key that is still frozen
  to `~/.osa` fails here instead of quietly polluting `$HOME`.
  """
  use ExUnit.Case, async: true

  @app :optimal_system_agent

  # Every app-env key config/config.exs derives from `Path.expand("~/.osa/...")`
  # and therefore freezes at compile time, with the suffix it must keep.
  @derived_paths [
    {:skills_dir, "skills"},
    {:episodic_dir, "memory/episodic"},
    {:mcp_config_path, "mcp.json"},
    {:data_dir, "data"},
    {:sessions_dir, "sessions"}
  ]

  defp config_dir, do: Application.fetch_env!(@app, :config_dir)

  test "the test suite's config_dir is an isolated tmp home, not the real ~/.osa" do
    # Guards the guard: if config_dir itself ever pointed back at the real home,
    # every assertion below would pass while the suite trashed $HOME.
    refute config_dir() == Path.expand("~/.osa"),
           "the suite must not run against the operator's real ~/.osa"

    assert String.starts_with?(config_dir(), System.tmp_dir!()),
           "expected an isolated tmp home, got #{config_dir()}"
  end

  for {key, suffix} <- @derived_paths do
    test "#{key} is derived from the runtime config_dir, not frozen to ~/.osa" do
      actual = Application.fetch_env!(@app, unquote(key))

      assert actual == Path.join(config_dir(), unquote(suffix)),
             """
             #{unquote(key)} is not tracking the runtime-resolved config_dir.

               config_dir: #{config_dir()}
               expected:   #{Path.join(config_dir(), unquote(suffix))}
               actual:     #{actual}

             config/config.exs freezes this key with Path.expand("~/.osa/...") at
             compile time; config/runtime.exs must re-derive it from config_dir.
             """

      refute String.starts_with?(actual, Path.expand("~/.osa")),
             "#{unquote(key)} still points into the operator's real home: #{actual}"
    end
  end

  test "config/test.exs keeps ownership of the keys it deliberately isolates" do
    # runtime.exs is loaded AFTER test.exs, so re-deriving these two there would
    # silently overwrite the suite's own isolation. They must stay under tmp,
    # but must NOT have been rewritten to config_dir/<...>.
    bootstrap_dir = Application.fetch_env!(@app, :bootstrap_dir)
    database = Application.fetch_env!(@app, OptimalSystemAgent.Store.Repo)[:database]

    # Pinned by SHAPE, not by exact spelling: the name now carries the same
    # per-run tag as the database. A single fixed `osa-test-bootstrap` was
    # isolated from the operator but shared by every RUN, so a `config.json`
    # written by one suite was read back by the next — and `Soul.soul_dir/0`
    # resolves USER.md / IDENTITY.md / SOUL.md out of this directory, which the
    # system prompt interpolates. What must hold is what the comment above says:
    # it stays under tmp, and runtime.exs has not rewritten it to config_dir.
    assert String.starts_with?(bootstrap_dir, Path.join(System.tmp_dir!(), "osa-test-bootstrap")),
           "expected config/test.exs's bootstrap_dir to survive runtime.exs, got #{bootstrap_dir}"

    refute bootstrap_dir == Path.join(Application.fetch_env!(@app, :config_dir), ""),
           "bootstrap_dir was rewritten to config_dir, overwriting the suite's own isolation"

    assert String.starts_with?(database, Path.join(System.tmp_dir!(), "osa-test-")),
           "expected config/test.exs's per-run database to survive runtime.exs, got #{database}"
  end
end
