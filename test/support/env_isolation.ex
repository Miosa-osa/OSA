defmodule OptimalSystemAgent.Test.EnvIsolation do
  @moduledoc """
  Snapshot + restore process-global Application env and OS env around a
  test, for the keys tests routinely mutate and hand-roll save/restore for
  (`OSA_HOME`, `OSA_PROMPT_GUARD`, provider/model keys like
  `:default_provider` or `:ollama_url`, ...).

  Both Application env (`Application.put_env/3`) and OS env
  (`System.put_env/2`) are process-global on the BEAM — a test that mutates
  one and forgets (or only partially restores) it leaks into every test that
  runs after it, in any file, `async: false` or not. The codebase already has
  this pattern by hand all over the test suite; this module is the one place
  to get the snapshot/restore right instead of re-deriving it per test.

  ## Usage

  As a `setup` — protects a whole module (or `describe`, if placed inside
  one):

      use OptimalSystemAgent.Test.EnvIsolation,
        env: ~w(OSA_HOME OSA_PROMPT_GUARD),
        app_env: [:default_provider, :ollama_url]

  Or ad hoc, when only one test needs it:

      test "..." do
        EnvIsolation.protect(env: ["OSA_HOME"])
        System.put_env("OSA_HOME", tmp)
        ...
      end

  `app:` overrides which OTP app `app_env` keys are read/restored against
  (default `:optimal_system_agent`).

  ## Ordering

  `protect/1` registers its restore via `ExUnit.Callbacks.on_exit/1`, and
  `on_exit` callbacks run LIFO. Calling `protect/1` (or placing `use
  EnvIsolation`) BEFORE a test mutates state and BEFORE any test-specific
  `on_exit` means this restore fires LAST — after teardown that still needs
  the mutated value to be live (e.g. `Trust.forget(cwd)` needing `OSA_HOME`
  still pointed at the temp workspace it was redirected to).
  """

  @default_app :optimal_system_agent

  defmacro __using__(opts) do
    quote do
      setup do
        OptimalSystemAgent.Test.EnvIsolation.protect(unquote(opts))
      end
    end
  end

  @doc """
  Capture the current value of each OS env (`:env`) and Application env
  (`:app_env`) key, as data — no side effects, no `ExUnit` dependency, so
  it is directly unit-testable.
  """
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    app = Keyword.get(opts, :app, @default_app)

    %{
      app: app,
      env: Map.new(Keyword.get(opts, :env, []), &{&1, System.get_env(&1)}),
      app_env: Map.new(Keyword.get(opts, :app_env, []), &{&1, Application.get_env(app, &1)})
    }
  end

  @doc """
  Restore exactly what `snapshot/1` captured. A key that was unset when
  snapshotted is deleted, not left at whatever a test set it to in between —
  that asymmetry (delete vs put back a stale default) is the usual bug in a
  hand-rolled `if old, do: put, else: delete`, so it is built in here once.
  """
  @spec restore(map()) :: :ok
  def restore(%{app: app, env: env, app_env: app_env}) do
    Enum.each(env, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    Enum.each(app_env, fn
      {k, nil} -> Application.delete_env(app, k)
      {k, v} -> Application.put_env(app, k, v)
    end)

    :ok
  end

  @doc """
  Snapshot now and register an `ExUnit.Callbacks.on_exit/1` that restores it
  when the current test finishes (pass or fail). Requires an `ExUnit` test
  context — call from a `setup` block or a test body, not from plain code.
  """
  @spec protect(keyword()) :: :ok
  def protect(opts \\ []) do
    snap = snapshot(opts)
    ExUnit.Callbacks.on_exit(fn -> restore(snap) end)
    :ok
  end
end
