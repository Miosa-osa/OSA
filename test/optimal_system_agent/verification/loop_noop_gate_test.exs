defmodule OptimalSystemAgent.Verification.LoopNoopGateTest do
  @moduledoc """
  The verification loop used to re-run a failing `test_command` even when the
  "fix" between two iterations changed nothing on disk — which is every
  iteration where the model answered in prose, or where the permission gate
  refused each command it emitted. The result of the re-run is known in
  advance, and OSA has burned whole benchmark budgets proving it.

  Ported from Prime Agent's autonomous no-op detector (MIT), see
  `docs/research/prime-agent.md` §6.3.
  """
  # `Verification.Loop` fingerprints via `WorkspaceFingerprint.capture(nil)`,
  # which resolves the directory through `Workspace.Cwd.get/0` — there is no
  # `:dir` (or `:working_dir`) option on `Loop.start_link/1` to point it
  # anywhere else. Left pointed at the real checkout (an ordinary, actively
  # edited dev tree), the "unchanged" fingerprint this test asserts on is a
  # hash of `git status`/`git diff HEAD`/untracked-file bytes for the WHOLE
  # repo — any other concurrently-running or still-finishing background work
  # that touches a file anywhere in the tree between the two captures this
  # test takes flips the hash and manufactures a second iteration, exactly the
  # `snap.iteration == 1` assertion below. `goal_verifier_test.exs` hit the
  # identical hazard and fixed it the same way: run against a throwaway,
  # `git init`'d temp directory nothing else in the suite ever touches, via
  # `Workspace.Cwd`'s GLOBAL `original_cwd` override (`async: false`, restored
  # in `on_exit`, same mechanism `settings_bom_test.exs` uses for the same
  # class of `File.cwd!`-adjacent global state).
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Verification.Loop
  alias OptimalSystemAgent.Verification.WorkspaceFingerprint
  alias OptimalSystemAgent.Workspace.Cwd

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa-noop-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
    {_, 0} = System.cmd("git", ["config", "user.email", "osa-test@example.com"], cd: tmp)
    {_, 0} = System.cmd("git", ["config", "user.name", "OSA Test"], cd: tmp)
    File.write!(Path.join(tmp, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: tmp)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "seed"], cd: tmp)

    prev_original = Cwd.original_cwd()
    Cwd.set_original_cwd(tmp)

    prev_provider_env = System.get_env("OSA_DEFAULT_PROVIDER")
    prev_default_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_ollama_url = Application.get_env(:optimal_system_agent, :ollama_url)
    System.delete_env("OSA_DEFAULT_PROVIDER")
    Application.put_env(:optimal_system_agent, :default_provider, :ollama)
    Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")

    on_exit(fn ->
      Cwd.set_original_cwd(prev_original)
      File.rm_rf(tmp)

      if prev_provider_env,
        do: System.put_env("OSA_DEFAULT_PROVIDER", prev_provider_env),
        else: System.delete_env("OSA_DEFAULT_PROVIDER")

      if prev_default_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_default_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_ollama_url,
        do: Application.put_env(:optimal_system_agent, :ollama_url, prev_ollama_url),
        else: Application.delete_env(:optimal_system_agent, :ollama_url)
    end)

    :ok
  end

  defp await_terminal(loop_id, deadline_ms \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await(loop_id, deadline)
  end

  defp do_await(loop_id, deadline) do
    case Loop.get_state(loop_id) do
      {:ok, %{status: status} = snap} when status != :running ->
        {:ok, snap}

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, other}
        else
          Process.sleep(25)
          do_await(loop_id, deadline)
        end
    end
  end

  test "a failing command in an unchanged workspace escalates instead of re-running" do
    OptimalSystemAgent.Test.VerificationGateHelper.allow_commands(["false"])

    loop_id = "noop_gate_#{System.unique_integer([:positive])}"

    # `false` always fails. There is no provider configured in test, so
    # `diagnose_and_fix/2` takes its `{:error, _}` branch: no fix is applied,
    # the workspace is therefore byte-identical, and iteration 2 must not run.
    {:ok, _pid} =
      Loop.start_link(
        loop_id: loop_id,
        test_command: "false",
        max_iterations: 5,
        timeout_ms: 30_000
      )

    assert {:ok, snap} = await_terminal(loop_id)
    assert snap.status == :escalated

    # The whole point of the gate, and the assertion that fails without it: the
    # loop stopped after ONE failure rather than spending all five iterations
    # re-proving it against a workspace no fix had touched.
    assert snap.iteration == 1
  end

  test "the gate cannot fire where the workspace cannot be fingerprinted" do
    # `unchanged?/2` is the only thing that can hold a re-run back, and it is
    # false whenever either side is `:unknown`. This is the false-positive
    # direction: a loop running outside a git repo must behave exactly as it
    # did before the gate existed.
    assert WorkspaceFingerprint.capture("/nonexistent/osa/path") == :unknown
    refute WorkspaceFingerprint.unchanged?(:unknown, :unknown)
  end
end
