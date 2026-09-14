defmodule OptimalSystemAgent.Security.Cvss do
  @moduledoc """
  CVSS v3.1 base-score calculator and vector parser.

  A finding without a severity score cannot be ranked, triaged, or reported
  with the rigor an engagement needs. This module turns a CVSS v3.1 base-metric
  vector into a numeric base score (0.0-10.0) and a severity rating, following
  the FIRST.org CVSS v3.1 specification exactly - including the spec's integer
  `roundup`, which avoids the float-rounding drift a naive `Float.ceil/2` would
  introduce.

  Only the eight BASE metrics are modeled (Temporal and Environmental are out of
  scope for an automated first-pass score):

      AV  Attack Vector          N (Network) | A (Adjacent) | L (Local) | P (Physical)
      AC  Attack Complexity      L (Low) | H (High)
      PR  Privileges Required    N (None) | L (Low) | H (High)
      UI  User Interaction       N (None) | R (Required)
      S   Scope                  U (Unchanged) | C (Changed)
      C   Confidentiality        N (None) | L (Low) | H (High)
      I   Integrity              N | L | H
      A   Availability           N | L | H

  ## Usage

      iex> Cvss.score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
      {:ok, %{base_score: 9.8, severity: :critical, vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}}

  A malformed or incomplete vector returns `{:error, reason}` rather than a
  fabricated score - a wrong severity is worse than a missing one.
  """

  @type metrics :: %{
          av: String.t(),
          ac: String.t(),
          pr: String.t(),
          ui: String.t(),
          s: String.t(),
          c: String.t(),
          i: String.t(),
          a: String.t()
        }

  @type result :: %{base_score: float(), severity: atom(), vector: String.t()}

  @av %{"N" => 0.85, "A" => 0.62, "L" => 0.55, "P" => 0.2}
  @ac %{"L" => 0.77, "H" => 0.44}
  # Privileges Required is scope-dependent: a Low/High privilege matters more
  # when the exploit crosses a scope boundary, so the Changed-scope weights are
  # higher. None is identical in both.
  @pr_unchanged %{"N" => 0.85, "L" => 0.62, "H" => 0.27}
  @pr_changed %{"N" => 0.85, "L" => 0.68, "H" => 0.5}
  @ui %{"N" => 0.85, "R" => 0.62}
  @cia %{"N" => 0.0, "L" => 0.22, "H" => 0.56}

  @metric_order [:av, :ac, :pr, :ui, :s, :c, :i, :a]
  @metric_labels %{av: "AV", ac: "AC", pr: "PR", ui: "UI", s: "S", c: "C", i: "I", a: "A"}

  @doc """
  Score a full CVSS v3.1 base vector string.

  Accepts the vector with or without the `CVSS:3.1/` prefix. Returns
  `{:ok, %{base_score, severity, vector}}` or `{:error, reason}`.
  """
  @spec score(String.t()) :: {:ok, result()} | {:error, String.t()}
  def score(vector) when is_binary(vector) do
    with {:ok, metrics} <- parse(vector) do
      score_metrics(metrics)
    end
  end

  def score(_), do: {:error, "vector must be a string"}

  @doc """
  Score from an already-parsed metrics map (string values, e.g. `%{av: "N", ...}`).
  """
  @spec score_metrics(metrics()) :: {:ok, result()} | {:error, String.t()}
  def score_metrics(%{} = m) do
    with {:ok, metrics} <- validate(m) do
      base = metrics_base_score(metrics)

      {:ok,
       %{
         base_score: base,
         severity: severity(base),
         vector: to_vector(metrics)
       }}
    end
  end

  @doc """
  Parse a vector string into a metrics map. Order-independent; ignores the
  `CVSS:3.1/` prefix and any Temporal/Environmental metrics that follow.
  """
  @spec parse(String.t()) :: {:ok, metrics()} | {:error, String.t()}
  def parse(vector) when is_binary(vector) do
    pairs =
      vector
      |> String.trim()
      |> String.split("/")
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "CVSS:")))
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(part, ":", parts: 2) do
          [k, v] -> Map.put(acc, String.upcase(k), String.upcase(v))
          _ -> acc
        end
      end)

    metrics =
      @metric_order
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(pairs, @metric_labels[key]) do
          nil -> acc
          v -> Map.put(acc, key, v)
        end
      end)

    validate(metrics)
  end

  def parse(_), do: {:error, "vector must be a string"}

  @doc "Severity rating band for a base score, per the CVSS v3.1 qualitative scale."
  @spec severity(number()) :: :none | :low | :medium | :high | :critical
  def severity(s) when s >= 9.0, do: :critical
  def severity(s) when s >= 7.0, do: :high
  def severity(s) when s >= 4.0, do: :medium
  def severity(s) when s > 0.0, do: :low
  def severity(_), do: :none

  @doc """
  Approximate base score (0.0-10.0) from a 0.0-1.0 exploit weight — for chain
  scoring where only an edge weight, not a full vector, is available.
  """
  @spec base_score(number()) :: float()
  def base_score(weight) when is_number(weight) do
    weight
    |> max(0.0)
    |> min(1.0)
    |> Kernel.*(10.0)
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp validate(metrics) do
    missing = Enum.reject(@metric_order, &Map.has_key?(metrics, &1))

    cond do
      missing != [] ->
        {:error,
         "missing base metric(s): " <>
           (missing |> Enum.map(&@metric_labels[&1]) |> Enum.join(", "))}

      not valid_values?(metrics) ->
        {:error, "invalid metric value in #{inspect(metrics)}"}

      true ->
        {:ok, metrics}
    end
  end

  defp valid_values?(m) do
    m.av in ~w(N A L P) and m.ac in ~w(L H) and m.pr in ~w(N L H) and
      m.ui in ~w(N R) and m.s in ~w(U C) and m.c in ~w(N L H) and
      m.i in ~w(N L H) and m.a in ~w(N L H)
  end

  defp metrics_base_score(m) do
    changed? = m.s == "C"

    iss = 1 - (1 - @cia[m.c]) * (1 - @cia[m.i]) * (1 - @cia[m.a])

    impact =
      if changed? do
        7.52 * (iss - 0.029) - 3.25 * :math.pow(iss - 0.02, 15)
      else
        6.42 * iss
      end

    pr = if changed?, do: @pr_changed[m.pr], else: @pr_unchanged[m.pr]
    exploitability = 8.22 * @av[m.av] * @ac[m.ac] * pr * @ui[m.ui]

    cond do
      impact <= 0 ->
        0.0

      changed? ->
        roundup(min(1.08 * (impact + exploitability), 10))

      true ->
        roundup(min(impact + exploitability, 10))
    end
  end

  # CVSS v3.1 spec Appendix A `Roundup`: round UP to one decimal place using
  # integer arithmetic, so 4.02 -> 4.1 and 4.00 -> 4.0 without float drift.
  defp roundup(input) do
    int_input = round(input * 100_000)

    if rem(int_input, 10_000) == 0 do
      int_input / 100_000
    else
      (Float.floor(int_input / 10_000) + 1) / 10
    end
  end

  defp to_vector(m) do
    "CVSS:3.1/" <>
      (@metric_order
       |> Enum.map(fn key -> "#{@metric_labels[key]}:#{m[key]}" end)
       |> Enum.join("/"))
  end
end
