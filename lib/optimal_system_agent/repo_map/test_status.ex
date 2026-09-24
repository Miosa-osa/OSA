defmodule OptimalSystemAgent.RepoMap.TestStatus do
  @moduledoc """
  Parses "did the last test run pass" out of a shell command and its raw
  output — no test runner is invoked here; `RepoMap.observe_tool_result/4`
  feeds this whatever a `shell_execute` tool call already produced, so the
  live repo model has test status without OSA running anything extra.

  Deliberately a small, closed set of well-known summary line shapes
  (ExUnit, pytest, cargo test, go test) rather than an attempt at every
  runner in existence — a command that LOOKS like a test run but whose
  output does not match any of them still records `:unknown` with the tail
  line of the output, so "a test command ran and here's roughly what it
  said" is never lost even when the format is not recognized.
  """

  @type status :: :passed | :failed | :unknown
  @type t :: %{status: status(), summary: String.t(), tool: String.t(), ran_at: integer()}

  @test_command_patterns [
    ~r/\bmix\s+test\b/,
    ~r/\bpytest\b/,
    ~r/\bpython3?\s+-m\s+pytest\b/,
    ~r/\bnpm\s+(?:run\s+)?test\b/,
    ~r/\byarn\s+test\b/,
    ~r/\bpnpm\s+test\b/,
    ~r/\bgo\s+test\b/,
    ~r/\bcargo\s+test\b/,
    ~r/\brspec\b/
  ]

  @doc """
  Parse `output` for a test-run summary, IF `command` looks like it invoked a
  test runner. Returns `:not_a_test_run` for anything else, so callers never
  have to pre-filter — this is safe to call on every `shell_execute` result.
  """
  @spec parse(String.t() | nil, String.t()) :: {:ok, t()} | :not_a_test_run
  def parse(command, output) when is_binary(command) and is_binary(output) do
    if test_command?(command) do
      {status, summary} = detect_summary(output)

      {:ok,
       %{
         status: status,
         summary: summary,
         tool: test_tool_name(command),
         ran_at: System.monotonic_time(:millisecond)
       }}
    else
      :not_a_test_run
    end
  end

  def parse(_command, _output), do: :not_a_test_run

  defp test_command?(command), do: Enum.any?(@test_command_patterns, &Regex.match?(&1, command))

  defp test_tool_name(command) do
    Enum.find_value(@test_command_patterns, "test", fn re ->
      case Regex.run(re, command) do
        [match] -> String.trim(match)
        _ -> nil
      end
    end)
  end

  # ── Summary-line detection, one well-known shape at a time ─────────────

  defp detect_summary(output) do
    cond do
      # ExUnit: "4 tests, 0 failures" (mix test's summary line).
      m = Regex.run(~r/(\d+) tests?, (\d+) failures?/, output) ->
        [_, total, failures] = m
        {status_from_zero(failures), "#{total} tests, #{failures} failures"}

      # pytest: "5 passed in 0.42s" / "2 failed, 5 passed in 1.10s".
      m = Regex.run(~r/(\d+) failed, (\d+) passed.* in [\d.]+s/, output) ->
        [_, failed, passed] = m
        {status_from_zero(failed), "#{failed} failed, #{passed} passed"}

      m = Regex.run(~r/(\d+) passed.* in [\d.]+s/, output) ->
        [_, passed] = m
        {:passed, "#{passed} passed"}

      # cargo test: "test result: ok. 12 passed; 0 failed; ...".
      m = Regex.run(~r/test result: (ok|FAILED)\.\s*(\d+) passed;\s*(\d+) failed/, output) ->
        [_, result, passed, failed] = m
        {if(result == "ok", do: :passed, else: :failed), "#{passed} passed, #{failed} failed"}

      # go test: a "FAIL" line anywhere outranks an "ok  <pkg>" line.
      Regex.match?(~r/^FAIL(\s|\t|$)/m, output) ->
        {:failed, "FAIL"}

      Regex.match?(~r/^ok\s+\S+/m, output) ->
        {:passed, "ok"}

      true ->
        {:unknown, tail_line(output)}
    end
  end

  defp status_from_zero("0"), do: :passed
  defp status_from_zero(_), do: :failed

  defp tail_line(output) do
    case output |> String.split("\n", trim: true) |> List.last() do
      nil -> ""
      line -> String.slice(line, 0, 200)
    end
  end
end
