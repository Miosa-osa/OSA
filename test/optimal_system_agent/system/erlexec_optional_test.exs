defmodule OptimalSystemAgent.System.ErlexecOptionalTest do
  @moduledoc """
  Regression: **OSA must boot as root.**

  `:erlexec` used to be an ordinary runtime dependency. Its C port program
  refuses to run as root ("Not allowed to run as root without setting effective
  user"), so inside every stock Docker image
  `Application.ensure_all_started(:optimal_system_agent)` returned
  `{:error, {:erlexec, {{:shutdown, {:failed_to_start_child, :exec, ...}}}}}`
  and `CLI.serve/0` MatchError'd on it — a total boot failure, for a feature
  (OpenComputers interactive PTY sessions) that a headless run never touches.

  Root cannot be simulated inside this suite, so the property under test is the
  one that MAKES the root case survivable and that a future refactor could
  silently undo:

    1. erlexec is not in the application tree, so no boot path can be taken down
       by it, as root or otherwise;
    2. it is still shipped in the release (load-only), so the PTY path can start
       it on demand;
    3. starting it is fallible-by-contract and cached, and its failure is
       reported rather than raised.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.System.Erlexec

  @status_key {Erlexec, :status}

  describe "the application tree does not depend on erlexec" do
    test "erlexec is absent from :optimal_system_agent's :applications" do
      apps = Application.spec(:optimal_system_agent, :applications) || []

      refute :erlexec in apps, """
      :erlexec is back in the application tree. That means
      Application.ensure_all_started(:optimal_system_agent) will try to start its
      port program, which REFUSES TO RUN AS ROOT — OSA would stop booting in
      every container again.

      Keep `runtime: false` on the dep in mix.exs and start it lazily via
      OptimalSystemAgent.System.Erlexec.ensure_started/0.
      """
    end

    test "erlexec is not started as a side effect of the app being up" do
      assert Application.spec(:optimal_system_agent, :vsn) != nil,
             "this test is meaningless unless the OSA app is loaded"

      started = Enum.map(Application.started_applications(), &elem(&1, 0))

      # Another test (or this suite's own PTY coverage) may have started it
      # lazily, which is fine — what must not happen is OSA's own boot doing it.
      # The application-tree assertion above is the strict form; this one only
      # documents the intent when nothing has touched a PTY yet.
      if :erlexec in started do
        assert Erlexec.available?(),
               "erlexec is running but Erlexec.available?/0 disagrees"
      end
    end
  end

  describe "the release still ships erlexec" do
    test "osagent lists erlexec as a load-only application" do
      apps =
        Mix.Project.config()
        |> Keyword.fetch!(:releases)
        |> Keyword.fetch!(:osagent)
        |> Keyword.fetch!(:applications)

      assert Keyword.get(apps, :erlexec) == :load, """
      The release must carry erlexec with mode `:load` — present on the code
      path, not started. Dropping the entry silently removes PTY support from
      every release build (a `runtime: false` dep is not assembled otherwise);
      changing it to :permanent reinstates the root boot failure.
      """
    end
  end

  describe "ensure_started/0" do
    setup do
      previous = :persistent_term.get(@status_key, :none)

      on_exit(fn ->
        case previous do
          :none -> Erlexec.reset()
          status -> :persistent_term.put(@status_key, status)
        end
      end)

      :ok
    end

    test "returns a tagged result and never raises" do
      Erlexec.reset()
      assert Erlexec.ensure_started() in [:ok] or match?({:error, _}, Erlexec.ensure_started())
    end

    test "is idempotent — repeated calls agree" do
      Erlexec.reset()
      first = Erlexec.ensure_started()
      assert Erlexec.ensure_started() == first
      assert Erlexec.ensure_started() == first
    end

    test "an unavailable erlexec degrades: no raise, a boolean, and a reason" do
      # Stand in for the root container, where the port program exits 4.
      :persistent_term.put(@status_key, {:error, {:port_exited_with_status, 4}})

      refute Erlexec.available?()
      reason = Erlexec.unavailable_reason()
      assert is_binary(reason)
      assert reason =~ "port_exited_with_status"
    end

    test "an available erlexec reports no reason" do
      :persistent_term.put(@status_key, :ok)
      assert Erlexec.available?()
      assert Erlexec.unavailable_reason() == nil
    end
  end

  describe "root?/0" do
    test "answers without raising" do
      assert is_boolean(Erlexec.root?())
    end
  end
end
