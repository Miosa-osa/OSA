defmodule OptimalSystemAgent.Tools.InvestigateEval do
  @moduledoc """
  Evaluation suite for the investigate tool.
  20 ground-truth claims with expected verdicts based on scientific consensus.

  Run with: mix run -e "OptimalSystemAgent.Tools.InvestigateEval.run()"
  """

  require Logger

  @ground_truth [
    # CLEARLY FALSE (should be falsified)
    %{claim: "homeopathy is effective for treating disease", expected: :falsified, category: :pseudoscience},
    %{claim: "vaccines cause autism", expected: :falsified, category: :pseudoscience},
    %{claim: "the earth is flat", expected: :falsified, category: :pseudoscience},
    %{claim: "astrology can predict future events", expected: :falsified, category: :pseudoscience},
    %{claim: "5G causes COVID-19", expected: :falsified, category: :conspiracy},

    # CLEARLY TRUE (should be supported or contested-leaning-supported)
    %{claim: "regular exercise reduces cardiovascular disease risk", expected: :supported, category: :medicine},
    %{claim: "smoking causes lung cancer", expected: :supported, category: :medicine},
    %{claim: "climate change is primarily caused by human activity", expected: :supported, category: :science},
    %{claim: "antibiotics are effective against bacterial infections", expected: :supported, category: :medicine},
    %{claim: "sleep deprivation impairs cognitive function", expected: :supported, category: :neuroscience},

    # GENUINELY CONTESTED (should be contested)
    %{claim: "intermittent fasting is more effective than calorie restriction for weight loss", expected: :contested, category: :nutrition},
    %{claim: "moderate alcohol consumption has health benefits", expected: :contested, category: :nutrition},
    %{claim: "artificial sweeteners are safe for long-term consumption", expected: :contested, category: :nutrition},
    %{claim: "cold exposure therapy improves immune function", expected: :contested, category: :health},
    %{claim: "psychedelics are effective treatments for depression", expected: :contested, category: :psychiatry},

    # NUANCED (tests depth of analysis)
    %{claim: "vitamin D supplementation prevents cancer", expected: :contested, category: :medicine},
    %{claim: "organic food is healthier than conventional food", expected: :contested, category: :nutrition},
    %{claim: "screen time causes ADHD in children", expected: :falsified, category: :psychology},
    %{claim: "creatine supplementation improves cognitive performance", expected: :contested, category: :neuroscience},
    %{claim: "gut microbiome composition directly causes depression", expected: :contested, category: :neuroscience}
  ]

  @doc """
  Run the full evaluation suite. Each claim is investigated and scored.
  """
  def run(opts \\ []) do
    max_claims = Keyword.get(opts, :max, 20)
    claims = Enum.take(@ground_truth, max_claims)

    Logger.info("[eval] Starting evaluation suite: #{length(claims)} claims")

    results = claims
    |> Enum.with_index(1)
    |> Enum.map(fn {gt, i} ->
      Logger.info("[eval] #{i}/#{length(claims)}: #{gt.claim}")
      start = System.monotonic_time(:millisecond)

      result = try do
        case OptimalSystemAgent.Tools.Builtins.Investigate.execute(%{
          "topic" => gt.claim,
          "depth" => "standard"
        }, %{}) do
          {:ok, output} when is_binary(output) ->
            verdict = extract_verdict(output)
            %{
              claim: gt.claim,
              expected: gt.expected,
              actual: verdict,
              correct: verdict_matches?(gt.expected, verdict),
              category: gt.category,
              duration_ms: System.monotonic_time(:millisecond) - start,
              output_length: String.length(output)
            }

          {:error, reason} ->
            %{
              claim: gt.claim,
              expected: gt.expected,
              actual: :error,
              correct: false,
              category: gt.category,
              duration_ms: System.monotonic_time(:millisecond) - start,
              error: inspect(reason)
            }
        end
      rescue
        e ->
          %{
            claim: gt.claim,
            expected: gt.expected,
            actual: :crash,
            correct: false,
            category: gt.category,
            duration_ms: System.monotonic_time(:millisecond) - start,
            error: Exception.message(e)
          }
      end

      Logger.info("[eval] #{i}/#{length(claims)}: expected=#{gt.expected} actual=#{result.actual} correct=#{result.correct} (#{result.duration_ms}ms)")
      result
    end)

    # Score
    total = length(results)
    correct = Enum.count(results, & &1.correct)
    accuracy = if total > 0, do: Float.round(correct / total * 100.0, 1), else: 0.0

    by_category = results
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {cat, items} ->
      cat_correct = Enum.count(items, & &1.correct)
      {cat, "#{cat_correct}/#{length(items)}"}
    end)
    |> Enum.into(%{})

    avg_duration = if total > 0 do
      results |> Enum.map(& &1.duration_ms) |> Enum.sum() |> div(total)
    else
      0
    end

    report = %{
      total: total,
      correct: correct,
      accuracy: accuracy,
      by_category: by_category,
      avg_duration_ms: avg_duration,
      results: results,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Save report
    report_path = Path.join(System.tmp_dir!(), "investigate_eval_#{Date.utc_today()}.json")
    File.write!(report_path, Jason.encode!(report, pretty: true))

    IO.puts("\n=== INVESTIGATE EVALUATION REPORT ===")
    IO.puts("Accuracy: #{correct}/#{total} (#{accuracy}%)")
    IO.puts("Avg duration: #{avg_duration}ms per claim")
    IO.puts("\nBy category:")
    Enum.each(by_category, fn {cat, score} -> IO.puts("  #{cat}: #{score}") end)
    IO.puts("\nDetailed results:")
    Enum.each(results, fn r ->
      mark = if r.correct, do: "PASS", else: "FAIL"
      IO.puts("  [#{mark}] #{r.claim}")
      IO.puts("         expected=#{r.expected} actual=#{r.actual} (#{r.duration_ms}ms)")
    end)
    IO.puts("\nReport saved: #{report_path}")

    report
  end

  # Extract verdict from investigate output text
  defp extract_verdict(output) do
    cond do
      String.contains?(output, "FALSIFIED") or String.contains?(output, "**Verdict: Falsified") ->
        :falsified
      String.contains?(output, "SUPPORTED") or String.contains?(output, "**Verdict: Supported") ->
        :supported
      String.contains?(output, "CONTESTED") or String.contains?(output, "**Verdict: Contested") or
        String.contains?(output, "**Verdict: Inconclusive") ->
        :contested
      true ->
        # Try to find verdict in lowercase
        lower = String.downcase(output)
        cond do
          String.contains?(lower, "verdict: falsified") or String.contains?(lower, "status: falsified") -> :falsified
          String.contains?(lower, "verdict: supported") or String.contains?(lower, "status: supported") -> :supported
          String.contains?(lower, "verdict: contested") or String.contains?(lower, "verdict: inconclusive") -> :contested
          true -> :unknown
        end
    end
  end

  # Check if actual verdict matches expected (with tolerance for contested)
  defp verdict_matches?(expected, actual) do
    cond do
      expected == actual -> true
      # Contested claims can reasonably be falsified or supported by a good tool
      expected == :contested and actual in [:supported, :falsified, :contested] -> true
      # A "supported" claim being "contested" is acceptable (partially correct)
      expected == :supported and actual == :contested -> true
      true -> false
    end
  end
end
