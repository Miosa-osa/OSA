defmodule OptimalSystemAgent.Tools.Audit do
  @moduledoc """
  Price every tool in the array by removing it, the way `Tools.Ablation` prices
  a read-tool output feature by removing it.

  ## Why this is a different instrument from `mix osa.ablate`

  `osa.ablate` moves one flag inside a tool's OUTPUT and asks whether a probe
  fact survived. This moves a whole tool OUT of the provider `tools` array and
  asks two questions instead:

    * `Δ remove` — how many prefix tokens the cut buys back. Exact, because it
      is `Providers.Anthropic.tools_payload_bytes/1` over the real
      `Registry.list_active/0` array with and without the tool, not a guess at
      what a schema "probably" costs.
    * `lost` — how many recorded tool calls the cut would have made impossible.
      Counted from the transcripts on disk, never from the model's prose about
      what it did.

  Same contract as the ablation table, and the same reading: a large `Δ remove`
  with `lost == 0` is fat. A small `Δ remove` with any `lost` bought something.

  ## What a tool costs, and why the unit is a declination

  Every schema in the array is re-sent on every request of every turn, so its
  cost is not paid once — it is paid per turn, and it is paid whether or not the
  tool is called. The second cost has no token figure: each tool is a decision
  the model must make and then decline. That one is not measured here, and this
  module must not pretend otherwise; what it measures is the token bill and the
  call record, and those two bound the argument without settling it.

  ## The corpus is evidence, and evidence has provenance

  `census/1` reads only structured tool-call rows:

    * `*.updates.jsonl` — `msg.tool_calls[].name` for the call and the
      following `role: "tool"` message for the outcome. Arguments here are the
      FULL argument map.
    * `osa-events.jsonl` — `type: "tool_call", phase: "start"` for the call and
      `type: "tool_result"` for the outcome. The `args` field on these rows is a
      display hint clipped at 60 characters and is never read.

  Outcome is classified on the RESULT TEXT, not on the `success` boolean:
  `tool_result` rows were observed carrying `success: true` alongside a body of
  `"Error: Permission denied: ..."`, so the boolean is not load-bearing and the
  text is.

  ## The confounds this module records rather than resolves

  A zero in the `calls` column has at least four causes and they are not
  interchangeable:

    1. The model never wanted the tool.
    2. The tool was not in the array, so the API could not emit its name. Under
       a native-tool provider a withheld tool is uncallable, not merely
       undocumented — see `Registry.list_active/0`.
    3. A competing tool was broken, so demand routed elsewhere.
    4. The corpus is benchmark containers, which never ask a question, never
       hand off to a person, and never resume yesterday's session.

  `reachable?` separates (2) from the rest by asking, per tool, whether
  `tool_search` can actually resolve its name — which is the sole mechanism by
  which `Agent.Loop.ToolDiscovery.widen/2` can put it back in the array. The
  others are not decidable from a corpus and are left to the reader with the
  numbers attached.
  """

  alias OptimalSystemAgent.Providers.Anthropic
  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.Handler, as: ToolSearch
  alias OptimalSystemAgent.Tools.Registry

  @typedoc "Per-tool census counters for one corpus."
  @type counts :: %{calls: non_neg_integer(), ok: non_neg_integer(), fail: non_neg_integer()}

  # A result body that starts with one of these is a failed call. Matched on the
  # head of the string only: a successful `file_read` of a file that happens to
  # contain the word "Error" must not be scored as a failure.
  @error_prefixes ~w(Error Error: error: Exception Permission\sdenied Tool\serror)

  @doc """
  Serialize a tool the way the provider does, so a byte is a billed byte.
  """
  @spec format_tool(map()) :: map()
  def format_tool(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => tool.parameters
    }
  end

  @doc """
  Exact bytes and estimated tokens for an array of registry tool maps.

  Tokens use OSA's own estimator; there is no tokenizer binary in this tree.
  Bytes are exact and are the figure to argue from. Measured against Anthropic's
  own count, the default array runs ~4.1 bytes/token.
  """
  @spec array_cost([map()]) :: %{bytes: non_neg_integer(), tokens: non_neg_integer()}
  def array_cost(tools) do
    payload = Enum.map(tools, &format_tool/1)
    json = Jason.encode!(payload)

    %{
      bytes: Anthropic.tools_payload_bytes(payload),
      tokens: OptimalSystemAgent.Utils.Tokens.estimate(json)
    }
  end

  @doc """
  What removing `name` from the live array saves.

  Computed by difference on the real array rather than by measuring the tool
  alone, because JSON punctuation between elements is billed too and a
  per-element measurement quietly drops it.
  """
  @spec removal_cost([map()], String.t()) :: %{
          bytes: non_neg_integer(),
          tokens: non_neg_integer()
        }
  def removal_cost(active, name) do
    before = array_cost(active)
    after_ = array_cost(Enum.reject(active, &(&1.name == name)))
    %{bytes: before.bytes - after_.bytes, tokens: before.tokens - after_.tokens}
  end

  @doc """
  Price a candidate cut: every name in `names` removed at once.

  ## This is additive, and that was worth checking

  The obvious worry is that pricing a cut by summing its parts double-counts or
  under-counts the JSON separators between array elements. It does neither. An
  `n`-element array carries `n - 1` separators, so removing one element drops
  that element plus exactly one separator, and doing it twice drops two of each
  — the same as removing both at once. `test/tools/audit_test.exs` asserts the
  equality rather than trusting this paragraph, and it caught the opposite claim
  in an earlier draft of this docstring.

  The one exception is a cut that empties the array, where the sum of the parts
  over-counts by one separator. No real proposal removes every tool, but the
  arithmetic is stated so a reader does not have to rediscover it.

  Computed as a joint difference anyway, because that is the figure being
  proposed and it should not depend on an invariant staying true.
  """
  @spec cut_cost([map()], [String.t()]) :: %{
          bytes: non_neg_integer(),
          tokens: non_neg_integer(),
          remaining: non_neg_integer()
        }
  def cut_cost(active, names) do
    drop = MapSet.new(names)
    kept = Enum.reject(active, &MapSet.member?(drop, &1.name))
    before = array_cost(active)
    after_ = array_cost(kept)

    %{
      bytes: before.bytes - after_.bytes,
      tokens: before.tokens - after_.tokens,
      remaining: length(kept)
    }
  end

  @doc """
  Can `tool_search` resolve this name?

  This is the whole of a withheld tool's reachability: `ToolDiscovery.widen/2`
  appends exactly what `resolve_tools/1` returns, so a name that does not
  resolve cannot be restored to the array and is unreachable no matter what the
  `should_defer?` docstrings promise.
  """
  @spec reachable?(String.t()) :: boolean()
  def reachable?(name) when is_binary(name) do
    %{"query" => "select:" <> name}
    |> ToolSearch.resolve_tools()
    |> Enum.any?(&(&1.name == name))
  rescue
    _ -> false
  end

  @doc """
  Walk `roots` and count every tool call, per corpus.

  A corpus is one root directory. Returns
  `%{corpus_label => %{tool_name => counts, ...}}` plus a `:__meta__` key per
  corpus carrying file and session totals, so a share can be computed without
  re-walking.
  """
  @spec census([{String.t(), Path.t()}]) :: map()
  def census(roots) do
    Map.new(roots, fn {label, root} -> {label, census_one(root)} end)
  end

  defp census_one(root) do
    files = jsonl_files(root)

    init = %{__meta__: %{files: 0, sessions: 0, root: root}}

    Enum.reduce(files, init, fn path, acc ->
      {counts, any?} = scan_file(path)

      acc
      |> merge_counts(counts)
      |> update_in([:__meta__, :files], &(&1 + 1))
      |> update_in([:__meta__, :sessions], &if(any?, do: &1 + 1, else: &1))
    end)
  end

  defp jsonl_files(root) do
    if File.dir?(root) do
      Path.wildcard(Path.join(root, "**/*.jsonl"))
    else
      []
    end
  end

  defp merge_counts(acc, counts) do
    Enum.reduce(counts, acc, fn {name, c}, a ->
      Map.update(a, name, c, fn prev ->
        %{calls: prev.calls + c.calls, ok: prev.ok + c.ok, fail: prev.fail + c.fail}
      end)
    end)
  end

  # Streams one transcript. Both formats are handled in one pass because a
  # single corpus root can hold both (a bench run directory carries
  # `osa-events.jsonl` beside per-task `*.updates.jsonl`).
  defp scan_file(path) do
    counts =
      path
      |> File.stream!([:read_ahead], :line)
      |> Enum.reduce(%{}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, row} -> scan_row(row, acc)
          _ -> acc
        end
      end)

    {counts, map_size(counts) > 0}
  rescue
    _ -> {%{}, false}
  end

  # `*.updates.jsonl`: the full message record.
  defp scan_row(%{"msg" => %{"role" => "assistant", "tool_calls" => calls}}, acc)
       when is_list(calls) do
    Enum.reduce(calls, acc, fn
      %{"name" => name}, a when is_binary(name) -> bump(a, name, :calls)
      _, a -> a
    end)
  end

  defp scan_row(%{"msg" => %{"role" => "tool", "name" => name, "content" => body}}, acc)
       when is_binary(name) do
    bump(acc, name, outcome(body))
  end

  # `osa-events.jsonl`: the streamed event log. Only `phase: "start"` is
  # counted; a call emits both a start and an end and counting both doubles it.
  defp scan_row(%{"type" => "tool_call", "phase" => "start", "name" => name}, acc)
       when is_binary(name),
       do: bump(acc, name, :calls)

  defp scan_row(%{"type" => "tool_result", "name" => name} = row, acc) when is_binary(name),
    do: bump(acc, name, outcome(row["result"]))

  defp scan_row(_, acc), do: acc

  defp outcome(body) when is_binary(body) do
    head = body |> String.trim_leading() |> String.slice(0, 40)
    if Enum.any?(@error_prefixes, &String.starts_with?(head, &1)), do: :fail, else: :ok
  end

  defp outcome(_), do: :ok

  defp bump(acc, name, key) do
    Map.update(acc, name, base(key), &Map.update!(&1, key, fn v -> v + 1 end))
  end

  defp base(key), do: %{calls: 0, ok: 0, fail: 0} |> Map.put(key, 1)

  @doc """
  Join the live registry against a census into one row per registered tool.

  Registered, not active: a tool absent from the array still has to answer for
  itself, and the reason it has no calls is the point of the `active` and
  `reachable` columns.
  """
  @spec rows(map()) :: [map()]
  def rows(census) do
    all = Registry.list_tools_direct()
    active = Registry.list_active()
    active_names = MapSet.new(active, & &1.name)
    hidden = Registry.model_hidden()

    labels = census |> Map.keys() |> Enum.sort()

    Enum.map(all, fn tool ->
      per = Map.new(labels, fn l -> {l, Map.get(census[l], tool.name, zero())} end)
      calls = per |> Map.values() |> Enum.map(& &1.calls) |> Enum.sum()
      ok = per |> Map.values() |> Enum.map(& &1.ok) |> Enum.sum()
      fail = per |> Map.values() |> Enum.map(& &1.fail) |> Enum.sum()
      in_array? = MapSet.member?(active_names, tool.name)

      %{
        name: tool.name,
        active: in_array?,
        hidden: MapSet.member?(hidden, tool.name),
        reachable: reachable?(tool.name),
        calls: calls,
        ok: ok,
        fail: fail,
        per_corpus: per,
        # Only a tool IN the array has a removal price; a withheld one already
        # costs the array nothing.
        removal: if(in_array?, do: removal_cost(active, tool.name), else: %{bytes: 0, tokens: 0})
      }
    end)
  end

  defp zero, do: %{calls: 0, ok: 0, fail: 0}

  @doc """
  Names the model tried to call that no tool answers to.

  Not a curiosity: `bash` and `bash_execute` against a tool actually named
  `shell_execute` is the model reaching for the canonical name and being told
  no, which is a naming defect priced in wasted turns.
  """
  @spec phantoms(map()) :: [{String.t(), non_neg_integer()}]
  def phantoms(census) do
    known = MapSet.new(Registry.list_tools_direct(), & &1.name)

    census
    |> Enum.flat_map(fn {_label, counts} ->
      counts |> Map.drop([:__meta__]) |> Enum.map(fn {n, c} -> {n, c.calls} end)
    end)
    |> Enum.reject(fn {n, _} -> MapSet.member?(known, n) end)
    |> Enum.reduce(%{}, fn {n, c}, a -> Map.update(a, n, c, &(&1 + c)) end)
    |> Enum.sort_by(fn {_, c} -> -c end)
  end
end
