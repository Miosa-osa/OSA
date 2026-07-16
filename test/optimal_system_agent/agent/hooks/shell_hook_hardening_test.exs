defmodule OptimalSystemAgent.Agent.Hooks.ShellHookHardeningTest do
  @moduledoc """
  Regression tests for ShellHook hardening:

    * payload values are shell-escaped, so a tool/model-influenced field
      containing shell metacharacters cannot execute (finding 11);
    * the hook actually runs — the invalid `:timeout` System.cmd option that
      previously made every hook silently fail is gone (finding 13).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks.ShellHook

  defp wait_for_file(path, attempts \\ 100)
  defp wait_for_file(_path, 0), do: :timeout

  defp wait_for_file(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(50)
      wait_for_file(path, attempts - 1)
    end
  end

  test "injected shell metacharacters in a payload value do not execute" do
    base = Path.join(System.tmp_dir!(), "osa_shellhook_#{System.unique_integer([:positive])}")
    log = base <> ".log"
    pwned = base <> ".pwned"

    on_exit(fn ->
      File.rm(log)
      File.rm(pwned)
    end)

    # The template writes {{evil}} to the log. If interpolation were unescaped,
    # the `; touch <pwned>` inside the value would run and create <pwned>.
    template = "echo {{evil}} >> #{log}"
    payload = %{evil: "hello; touch #{pwned}"}

    ShellHook.execute(template, payload, timeout: 5_000)

    # The hook DID run (log appears) — proving the :timeout-option bug is fixed.
    assert :ok = wait_for_file(log)

    contents = File.read!(log)
    # The metacharacters were treated as literal text...
    assert contents =~ "; touch #{pwned}"
    # ...and the injection did NOT execute.
    refute File.exists?(pwned)
  end
end
