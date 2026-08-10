defmodule OptimalSystemAgent.Usage.Render do
  @moduledoc """
  Turns a `OptimalSystemAgent.Usage.report/1` into lines of text.

  A pure function returning a list of strings rather than something that
  writes to stdout, so the honesty rules the report encodes — "not reported by
  this provider" must never render as `0`, the provider's report and OSA's own
  measurement must never share a heading — can be asserted in a test without
  capturing IO.
  """

  @reset "\e[0m"
  @bold "\e[1m"
  @dim "\e[2m"
  @green "\e[32m"
  @yellow "\e[33m"
  @cyan "\e[36m"

  @doc "Render a report as a list of lines."
  @spec lines(map(), keyword()) :: [String.t()]
  def lines(report, opts \\ [])

  def lines(%{entries: []}, _opts) do
    [
      "",
      "  #{@bold}Usage#{@reset}",
      "",
      "  #{@dim}No provider is configured yet. Run#{@reset} #{@cyan}osa setup#{@reset}#{@dim}.#{@reset}",
      ""
    ]
  end

  def lines(%{entries: entries}, opts) do
    all? = Keyword.get(opts, :all, false)

    header = ["", "  #{@bold}Usage#{@reset}"]

    body = Enum.flat_map(entries, &provider_block/1)

    footer =
      if all? do
        [""]
      else
        [
          "",
          "  #{@dim}Showing the active provider.#{@reset} #{@cyan}/usage all#{@reset} #{@dim}shows every configured one.#{@reset}",
          ""
        ]
      end

    header ++ body ++ footer
  end

  # ── One provider ────────────────────────────────────────────────────────

  defp provider_block(entry) do
    tags =
      [
        if(entry.active?, do: "#{@green}active#{@reset}"),
        "#{@dim}#{mode_label(entry.auth_mode)}#{@reset}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" #{@dim}·#{@reset} ")

    ["", "  #{@bold}#{entry.display_name}#{@reset}  #{tags}"] ++
      account_block(entry.account) ++ measured_block(entry.measured)
  end

  defp mode_label(:subscription), do: "subscription"
  defp mode_label(:external_cli), do: "signed in via its own CLI"
  defp mode_label(:api_key), do: "API key"
  defp mode_label(_), do: "not configured"

  # ── The provider's report ───────────────────────────────────────────────

  defp account_block(account) do
    heading = ["    #{@dim}Your account — as reported by the provider#{@reset}"]

    rows =
      case account do
        %{status: :not_connected} ->
          ["      #{@dim}not connected#{@reset}"]

        %{status: :withheld, fields: fields} ->
          field_rows(fields) ++
            ["      #{@yellow}quota not shown#{@reset} #{@dim}— see the note below#{@reset}"]

        %{status: :awaiting, fields: fields} ->
          field_rows(fields) ++
            ["      #{@dim}quota not reported yet#{@reset}"]

        %{status: :not_reported, fields: []} ->
          ["      #{@dim}not reported by this provider#{@reset}"]

        %{status: :not_reported, fields: fields} ->
          field_rows(fields) ++
            ["      #{@dim}remaining quota not reported by this provider#{@reset}"]

        %{fields: []} ->
          ["      #{@dim}not reported by this provider#{@reset}"]

        %{fields: fields} ->
          field_rows(fields)
      end

    heading ++ rows ++ note_rows(account[:note])
  end

  defp field_rows(fields) do
    for {label, value} <- fields do
      "      #{@dim}#{pad(label)}#{@reset} #{value}"
    end
  end

  # ── OSA's own measurement ───────────────────────────────────────────────

  defp measured_block(nil), do: []

  defp measured_block(m) do
    rows =
      [
        "      #{@dim}#{pad("Input")}#{@reset} #{tokens(m.input_tokens)}",
        "      #{@dim}#{pad("Output")}#{@reset} #{tokens(m.output_tokens)}"
      ] ++ cache_rows(m) ++ cost_rows(m)

    ["", "    #{@dim}This session — OSA's own count of what it ran#{@reset}"] ++
      rows ++ note_rows(m[:cost_note])
  end

  defp cache_rows(%{cache_read_tokens: r}) when is_number(r) and r > 0,
    do: ["      #{@dim}#{pad("Cache read")}#{@reset} #{tokens(r)}"]

  defp cache_rows(_), do: []

  defp cost_rows(%{cost_usd: c}) when is_number(c),
    do: ["      #{@dim}#{pad("Cost")}#{@reset} $#{:erlang.float_to_binary(c / 1, decimals: 4)}"]

  defp cost_rows(_), do: []

  # ── Shared ──────────────────────────────────────────────────────────────

  defp note_rows(nil), do: []
  defp note_rows(""), do: []

  defp note_rows(note) do
    note
    |> wrap(72)
    |> Enum.map(&"    #{@dim}#{&1}#{@reset}")
  end

  defp wrap(text, width) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [] ->
          [word]

        [line | rest] ->
          if String.length(line) + 1 + String.length(word) <= width,
            do: [line <> " " <> word | rest],
            else: [word, line | rest]
      end
    end)
    |> Enum.reverse()
  end

  defp pad(label), do: String.pad_trailing(to_string(label), 14)

  @doc "Format a token count compactly: `12.4K`, `1.2M`."
  @spec tokens(number()) :: String.t()
  def tokens(n) when is_number(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M tokens"

  def tokens(n) when is_number(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K tokens"
  def tokens(n) when is_number(n), do: "#{round(n)} tokens"
  def tokens(_), do: "0 tokens"
end
