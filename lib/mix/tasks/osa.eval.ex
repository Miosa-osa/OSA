defmodule Mix.Tasks.Osa.Eval do
  @shortdoc "Score a scanner against a fixture catalog"

  @moduledoc """
  Independent eval harness. Prints precision, recall, and F0.5.

      mix osa.eval
      mix osa.eval --catalog test/fixtures/pentest_eval/catalog.json
      mix osa.eval --catalog path/to/catalog.json --root path/to/fixture

  Local fixtures only. Not an XBEN score.
  """

  use Mix.Task

  alias OptimalSystemAgent.Security.EvalHarness

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _} =
      OptionParser.parse(argv, strict: [catalog: :string, root: :string])

    catalog =
      Keyword.get(opts, :catalog) ||
        Path.join(File.cwd!(), "test/fixtures/pentest_eval/catalog.json")

    root = Keyword.get(opts, :root) || Path.dirname(catalog)

    Mix.Task.run("app.config")

    case EvalHarness.run(catalog: catalog, root: root) do
      {:ok, score} ->
        Mix.shell().info(
          "osa.eval  precision=#{fmt(score.precision)} recall=#{fmt(score.recall)} " <>
            "f0.5=#{fmt(score.f0_5)} tp=#{score.true_positives} " <>
            "fp=#{score.false_positives} fn=#{score.false_negatives}"
        )

        :ok

      {:error, reason} ->
        Mix.shell().error("osa.eval failed: #{reason}")
        exit({:shutdown, 2})
    end
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 3)
  defp fmt(n), do: to_string(n)
end
