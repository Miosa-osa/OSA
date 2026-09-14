defmodule OptimalSystemAgent.Test.CiSignal do
  @moduledoc """
  Detects whether the current `mix test` run is happening under the
  toolchain CI pins, as opposed to an arbitrary local dev shell.

  `ci.yml` sets `ELIXIR_VERSION` and `OTP_VERSION` as workflow-level `env:`,
  which GitHub Actions exports as real shell environment variables to every
  step — including whichever step runs `mix test`. Their presence is
  therefore exactly the "this run is on the pinned toolchain" signal, with
  no extra plumbing needed. Nothing exports those names in a normal local
  shell.

  Lives in `test/support` (not inline in a single test file) because a
  compile-time `@tag skip: ...` expression cannot call a function defined
  earlier in the *same* module being compiled — it has to reach an
  already-compiled module, which `test/support` is by the time any `.exs`
  test file compiles (see `elixirc_paths(:test)` in `mix.exs`).
  """

  @doc """
  True when both `ELIXIR_VERSION` and `OTP_VERSION` are present and
  non-empty in `env`.

  Takes the environment as data (default: the real `System.get_env/0`) so
  the decision is testable without mutating global OS env state.
  """
  @spec pinned_toolchain?(%{optional(String.t()) => String.t()}) :: boolean()
  def pinned_toolchain?(env \\ System.get_env()) do
    present?(env["ELIXIR_VERSION"]) and present?(env["OTP_VERSION"])
  end

  defp present?(v), do: is_binary(v) and v != ""
end
