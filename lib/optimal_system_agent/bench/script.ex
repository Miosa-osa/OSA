defmodule OptimalSystemAgent.Bench.Script do
  @moduledoc """
  Scripted model responses for the two controls, replayed through the real
  agent loop and the real tools by the mock provider (`:mock_provider_script`).

    * `oracle` - replays the task's `reference`: a list whose elements are
      either a list of `{tool_name, args}` calls issued together in one model
      turn, or `{:answer, text}`, the final reply. `"$WORKDIR"` in any string
      argument is replaced with the task's workspace. Every task must PASS
      under its oracle, which proves the task is solvable and its checker
      recognises a correct solution.
    * `nop` - answers immediately without touching anything. Every task must
      FAIL under it, which proves the checker is not satisfied by the starting
      state.

  The script is stateless: the step to play is the number of assistant turns
  already in the conversation, so a harness nudge that adds an extra round
  simply replays the final answer.
  """

  @nop_answer "I have not made any changes."

  @doc "The response function for `mode` (`:oracle` or `:nop`)."
  @spec responder(:oracle | :nop, [term()], Path.t()) :: (list(), keyword() -> map())
  def responder(:nop, _reference, _workdir) do
    fn messages, _opts -> respond(messages, {:answer, @nop_answer}, 0) end
  end

  def responder(:oracle, reference, workdir) do
    steps = Enum.map(reference, &substitute(&1, workdir))

    fn messages, _opts ->
      index = assistant_turns(messages)
      step = Enum.at(steps, index) || final_answer(steps)
      respond(messages, step, index)
    end
  end

  defp final_answer(steps) do
    Enum.find(Enum.reverse(steps), {:answer, "Done."}, &match?({:answer, _}, &1))
  end

  defp respond(messages, {:answer, text}, _index) do
    %{content: text, tool_calls: [], usage: usage(messages, text)}
  end

  defp respond(messages, calls, index) when is_list(calls) do
    tool_calls =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {{name, args}, i} ->
        %{id: "bench_#{index}_#{i}", name: name, arguments: args}
      end)

    %{content: "", tool_calls: tool_calls, usage: usage(messages, inspect(calls))}
  end

  # A rough, clearly-synthetic usage figure (4 bytes per token) so the smoke
  # run exercises the token columns end to end. Never priced: the mock model
  # has no rate card.
  defp usage(messages, output) do
    input = messages |> Enum.map(&message_bytes/1) |> Enum.sum()
    %{input_tokens: div(input, 4), output_tokens: max(div(byte_size(output), 4), 1)}
  end

  defp message_bytes(%{} = m) do
    case Map.get(m, :content) || Map.get(m, "content") do
      c when is_binary(c) -> byte_size(c)
      c when is_list(c) -> c |> inspect() |> byte_size()
      _ -> 0
    end
  end

  defp message_bytes(_), do: 0

  defp assistant_turns(messages) do
    Enum.count(messages, fn m ->
      is_map(m) and (Map.get(m, :role) || Map.get(m, "role")) in ["assistant", :assistant]
    end)
  end

  defp substitute({:answer, text}, workdir), do: {:answer, sub(text, workdir)}

  defp substitute(calls, workdir) when is_list(calls) do
    Enum.map(calls, fn {name, args} -> {name, sub(args, workdir)} end)
  end

  defp sub(s, workdir) when is_binary(s), do: String.replace(s, "$WORKDIR", workdir)
  defp sub(%{} = m, workdir), do: Map.new(m, fn {k, v} -> {k, sub(v, workdir)} end)
  defp sub(l, workdir) when is_list(l), do: Enum.map(l, &sub(&1, workdir))
  defp sub(other, _), do: other
end
