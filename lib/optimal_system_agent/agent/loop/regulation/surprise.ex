defmodule OptimalSystemAgent.Agent.Loop.Regulation.Surprise do
  @moduledoc """
  Cheap surprise detection for risky tool calls (item 11).

  "Risky" is: an edit/write tool, or a `shell_execute` call whose command is
  NOT provably read-only (`ShellExecute.ReadOnly.provably_read_only?/1` — the
  one place that answer is decided; see that module's moduledoc for why a
  second read-only matcher would drift). For those calls, the expected
  outcome is cheaply INFERRED rather than asked of the model — "this call
  succeeds" — because that is what issuing the call means: nobody edits a
  file expecting the edit to fail, and nobody runs a mutating command
  expecting it to error. A one-line `expected_outcome` argument is honoured
  when the model supplies one (some tool schemas allow free-form extra
  fields), purely for the cause text; it never changes which calls count as
  a surprise.

  A surprise is recorded when the actual result CONTRADICTS that: the call
  errored, was blocked, or (for shell) exited non-zero for a reason
  `Shell.ExitClassifier` cannot excuse as benign (grep's "no matches", `test`
  false, `diff` "differs" are not surprises — they are the tool answering
  truthfully).

  No extra model call, no schema change, no network round-trip: everything
  here is a string match against a result the tool already produced. Feeds
  the pain score via `state[:regulation_surprise_count]`
  (`Signals.collect/3` reads it); does not itself halt or nudge anything.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Shell.ExitClassifier
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.ReadOnly

  @write_edit_tools ~w(file_write file_edit file_create write_file edit_file
                       apply_patch str_replace str_replace_editor create_file
                       file_append multi_edit notebook_edit)

  @exit_pattern ~r/^Exit (-?\d+):/

  @doc """
  Score this iteration's tool results for surprises and fold the count onto
  `state`. Idempotent per call — always safe to invoke once per iteration.
  """
  @spec check(list(), list(), map()) :: map()
  def check(results, tool_calls, state) when is_list(results) and is_list(tool_calls) do
    surprises =
      results
      |> Enum.flat_map(&surprise_for(&1, state))

    if surprises == [] do
      state
    else
      Enum.each(surprises, &log_surprise(&1, state))

      Map.update(state, :regulation_surprise_count, length(surprises), &(&1 + length(surprises)))
    end
  end

  def check(_results, _tool_calls, state), do: state

  defp surprise_for({tc, result}, _state) when is_map(tc) do
    with true <- risky?(tc),
         result_str when is_binary(result_str) <- result_text(result),
         true <- contradicts?(tc, result_str) do
      [{tc, result_str}]
    else
      _ -> []
    end
  end

  defp surprise_for(_, _state), do: []

  defp result_text({_msg, result_str}) when is_binary(result_str), do: result_str
  defp result_text(result_str) when is_binary(result_str), do: result_str
  defp result_text(_), do: nil

  defp risky?(%{name: "shell_execute"} = tc) do
    case get_arg(tc, "command") do
      command when is_binary(command) and command != "" ->
        not ReadOnly.provably_read_only?(command)

      _ ->
        false
    end
  end

  defp risky?(%{name: name}), do: write_or_edit_tool?(name)
  defp risky?(_), do: false

  defp write_or_edit_tool?(name) do
    downcased = name |> to_string() |> String.downcase()

    name in @write_edit_tools or
      String.contains?(downcased, "write") or
      String.contains?(downcased, "edit") or
      String.contains?(downcased, "patch")
  end

  # Shell: a non-zero exit is a surprise unless the specific command/exit-code
  # pair is a KNOWN benign answer (grep "no matches", `test` false, …).
  defp contradicts?(%{name: "shell_execute"} = tc, result_str) do
    case Regex.run(@exit_pattern, result_str) do
      [_, code_str] ->
        exit_code = String.to_integer(code_str)
        command = get_arg(tc, "command") || ""
        not ExitClassifier.benign_exit?(command, exit_code)

      nil ->
        false
    end
  end

  # Everything else risky (edit/write): a surprise is an explicit error/block.
  # "No change needed" is deliberately NOT a surprise here — it is a
  # legitimate idempotent no-op (Stall treats it the same way), not a
  # contradicted expectation.
  defp contradicts?(_tc, result_str) do
    trimmed = String.trim_leading(result_str)
    String.starts_with?(trimmed, "Error:") or String.starts_with?(trimmed, "Blocked:")
  end

  defp get_arg(%{arguments: args}, key) when is_map(args) do
    Map.get(args, key) || Map.get(args, String.to_atom(key))
  end

  defp get_arg(_, _), do: nil

  defp log_surprise({tc, result_str}, state) do
    expected = get_arg(tc, "expected_outcome") || "succeeds"

    Bus.emit(:system_event, %{
      event: :surprise,
      session_id: Map.get(state, :session_id),
      tool: tc.name,
      expected: to_string(expected),
      actual_preview: result_str |> to_string() |> String.slice(0, 160)
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
