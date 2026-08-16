defmodule OptimalSystemAgent.Providers.ContextProbeFitsInsideACallTest do
  @moduledoc """
  The context-window probe must not outlast the `GenServer.call` it runs inside.

  `Loop.handle_call({:swap_provider, ...})` calls
  `Registry.effective_context_window/2` INSIDE the callback, and the ETS
  override that makes the swap real is written only AFTER that returns.
  `session_routes.ex` calls `forget_context_window/1` immediately before the
  swap, so the cache is cold by construction and the probe always runs.

  Both callers use `GenServer.call/2` with no timeout — the Elixir default,
  **5000 ms** (`session_manager.ex`, `channels/cli/commands.ex`).

  The probe advertises a 3s budget (`@probe_timeout_ms`) and its own comment
  promises "a slow or broken Ollama can never stall a request path". That was
  not true. `receive_timeout` bounds only the wait for a RESPONSE; it does not
  bound connection establishment or pool checkout, which fall back to Finch's
  own 5s default. Measured against a black-holed host:

      receive_timeout only   -> 5017 ms
      + connect_options      -> 3002 ms

  5017 ms inside a 5000 ms call. The caller gives up 17 ms before the server
  finishes — and the server then completes the swap anyway, writing the ETS
  override. A model switch that LANDS and REPORTS FAILURE, which is the same
  shape as the picker bug ("an operation that succeeds while the interface says
  otherwise") and reached on every model change against a remote or half-open
  Ollama.

  The margin is the whole point, so the assertion is on the margin and not on a
  round number.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry

  # RFC 5737 / RFC 1918 black hole: routable in principle, answers never.
  # `connect` hangs rather than being refused, which is the remote-Ollama and
  # half-open-socket case — a REFUSED connection returns instantly and would
  # make this test vacuous.
  @blackhole "http://10.255.255.1:11434"

  # Elixir's `GenServer.call/2` default. The number this probe has to fit under.
  @genserver_call_default_ms 5_000

  setup do
    prev_url = Application.get_env(:optimal_system_agent, :ollama_url)
    Application.put_env(:optimal_system_agent, :ollama_url, @blackhole)

    # A model name nothing can answer for, so the probe is actually attempted
    # rather than served from the static catalogue.
    model = "probe-victim-#{System.unique_integer([:positive])}:latest"
    Registry.forget_context_window(model)

    on_exit(fn ->
      Registry.forget_context_window(model)

      if prev_url,
        do: Application.put_env(:optimal_system_agent, :ollama_url, prev_url),
        else: Application.delete_env(:optimal_system_agent, :ollama_url)
    end)

    {:ok, model: model}
  end

  test "an unreachable Ollama cannot outlast the call the probe runs inside", %{model: model} do
    started = System.monotonic_time(:millisecond)
    _window = Registry.effective_context_window(model, :ollama)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < @genserver_call_default_ms,
           """
           the context probe took #{elapsed}ms against an unreachable host, at or past the \
           #{@genserver_call_default_ms}ms `GenServer.call` default it runs inside.

           `Loop.handle_call({:swap_provider, ...})` writes the provider override AFTER this \
           returns, so the caller times out while the server completes the swap: the model \
           change lands and is reported as a failure.

           `receive_timeout` alone does not bound connect or pool checkout — those fall back \
           to Finch's own 5s default. The probe needs an explicit connect bound to mean what \
           its own comment says it means.
           """

    # And it must still leave real headroom, not merely squeak under. A probe
    # that finishes at 4999ms satisfies the line above and is still a defect the
    # moment anything else sits in that mailbox ahead of it.
    assert elapsed < @genserver_call_default_ms - 1_000,
           "the probe finished at #{elapsed}ms — under the call budget, but with no margin " <>
             "for anything queued ahead of it"
  end

  test "a probe that cannot resolve still answers with a usable window", %{model: model} do
    # Bounding the probe must not turn "I could not ask" into a crash or a nil
    # that some caller divides by. The documented behaviour — fall back to the
    # static table / config default — has to survive the bound.
    window = Registry.effective_context_window(model, :ollama)

    assert is_integer(window) and window > 0,
           "a failed probe must still yield a usable context window, got #{inspect(window)}"
  end
end
