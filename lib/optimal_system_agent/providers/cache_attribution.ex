defmodule OptimalSystemAgent.Providers.CacheAttribution do
  @moduledoc """
  Prompt-cache break attributor — names the culprit when the provider's
  reported cache read drops.

  OSA carries a large static prefix (system blocks + tool schemas) on every
  request. Whether that prefix is actually served from the provider's prompt
  cache is the difference between a warm request and a full re-prefill, and
  until now the only signal was an aggregate `cache_read_input_tokens` number
  with nothing attached to it. "The cache missed" is not actionable;
  "tool `bash`'s schema changed" is.

  Ported from Claude Code's per-request cache-stability watchdog. The shape:

    1. Fingerprint each request at the SAME granularity the provider's cache
       keys on — per system block, per tool, per message — never the whole
       payload as one blob. A whole-payload hash can only ever say "something
       changed".
    2. Keep the previous request's fingerprint for the same cache scope.
    3. On the next response, compare the provider's reported
       `cache_read_input_tokens` against the previous one. **Only when it
       actually drops** is the fingerprint diff rendered into a verdict. A
       diff with a healthy cache read is not a break — the prefix before the
       change was still served, and reporting it would be noise.

  ## Cost

  Nothing is stored but hashes: `:erlang.phash2/1` per system block, per tool,
  and per message, plus a hash of the residual request params. No payload is
  retained, so leaving this on costs one traversal of a structure the caller
  just built, and a few hundred bytes of ETS per session. See
  `test/providers/cache_attribution_test.exs` for the measured figure on a
  realistic ~47k-token body.

  ## Verdict vocabulary

  Deliberately close to Claude Code's, because the strings are the product:

      model changed (X → Y)
      system prompt changed (block 2/3, +412 chars)
      system prompt changed (+1/-0 blocks)
      tools changed (+1/-0 tools: +web_fetch)
      tools changed (tool prompt/schema changed, same tool set: bash)
      cache_control changed (scope or TTL)
      request params changed (max_tokens/thinking/effort)
      message history mutated at index 4/12
      possible 5min TTL expiry (prompt unchanged)
      likely server-side (prompt unchanged, <5min gap)

  Multiple verdicts join with `" · "`, most-structural first, because a model
  swap and a tool-set change can land in the same request and only naming both
  is honest.

  ## Scope key

  Comparison is per **cache scope** — the session by default. Two sessions
  interleaving requests must not be diffed against each other, or every turn
  looks like a break. Out-of-band callers (compactor, verifier) that carry no
  session id share the `"default"` scope; they have their own prefix and their
  own cache line, so they are not mixed into a live session's readout.

  ## Not verified against a live provider

  Every claim this module makes is derived from the provider's own reported
  `cache_read_input_tokens`. The module has never been exercised against a
  live Anthropic endpoint from this machine — see the test module for what IS
  covered.
  """

  require Logger

  @table :osa_cache_attribution

  # Anthropic's default `ephemeral` cache entry lives 5 minutes. A drop with a
  # byte-identical prompt across a longer gap is expiry, not a break.
  @default_ttl_ms 5 * 60 * 1000

  @typedoc "Opaque per-request fingerprint. Hashes only — never payload."
  @type fingerprint :: %{
          model: term(),
          system: [map()],
          tools: [map()],
          messages: [non_neg_integer()],
          params: non_neg_integer()
        }

  @typedoc "Verdict rendered when the reported cache read drops."
  @type verdict :: String.t()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Cache scope key for a provider call, from its `opts`.

  Prefers an explicit `:cache_scope`, then `:session_id`. Callers with neither
  land in `"default"`.
  """
  @spec scope(keyword()) :: String.t()
  def scope(opts) when is_list(opts) do
    case Keyword.get(opts, :cache_scope) || Keyword.get(opts, :session_id) do
      s when is_binary(s) and s != "" -> s
      s when is_atom(s) and not is_nil(s) -> Atom.to_string(s)
      _ -> "default"
    end
  end

  def scope(_), do: "default"

  @doc """
  Fingerprint a provider request body.

  Hashes at cache-key granularity: one entry per system block, one per tool
  (name kept separate from schema so "same tool set, schema changed" is
  distinguishable from "tool added"), one per message, and one rollup for
  every remaining top-level request parameter.

  Accepts atom- or string-keyed bodies; Anthropic builds atom-keyed maps and
  the block lists inside are string-keyed.
  """
  @spec fingerprint(map()) :: fingerprint()
  def fingerprint(body) when is_map(body) do
    %{
      model: get(body, :model),
      system: system_fingerprint(get(body, :system)),
      tools: tools_fingerprint(get(body, :tools)),
      messages: messages_fingerprint(get(body, :messages)),
      params: params_fingerprint(body)
    }
  end

  def fingerprint(_), do: %{model: nil, system: [], tools: [], messages: [], params: 0}

  @doc """
  Record a completed request and attribute a cache break if one occurred.

  `usage` is the provider usage map OSA already threads through pricing and
  session state — `:cache_read_input_tokens` is the only field read.

  Returns `{:break, verdict}` when the reported cache read dropped against the
  previous request in this scope, `:ok` otherwise. The verdict is also logged
  as `[PROMPT CACHE] …` and stashed for `last_break/1`.

  Always records the current fingerprint, so a break is attributed exactly
  once and the next request diffs against this one.
  """
  @spec observe(String.t(), fingerprint(), map() | nil) ::
          :ok | {:break, verdict()} | {:cold, verdict()}
  def observe(key, fp, usage) when is_binary(key) and is_map(fp) do
    if enabled?() do
      now = System.system_time(:millisecond)
      read = cache_read(usage)
      prev = fetch(key)
      cold_run = next_cold_run(prev, fp, read)

      put(key, {fp, read, now, cold_run})

      case prev do
        {prev_fp, prev_read, prev_at, _}
        when is_integer(prev_read) and prev_read > 0 and read < prev_read ->
          report_break(key, prev_fp, fp, prev_read, read, now - prev_at, now)

        {prev_fp, prev_read, prev_at}
        when is_integer(prev_read) and prev_read > 0 and read < prev_read ->
          report_break(key, prev_fp, fp, prev_read, read, now - prev_at, now)

        _ ->
          maybe_report_cold(key, cold_run, read)
      end
    else
      :ok
    end
  rescue
    # Attribution is diagnostics. It must never be able to fail a request.
    e ->
      Logger.debug("[PROMPT CACHE] attribution skipped: #{Exception.message(e)}")
      :ok
  end

  def observe(_, _, _), do: :ok

  # ---------------------------------------------------------------------------
  # A cache that never warmed
  # ---------------------------------------------------------------------------
  #
  # `observe/3` could only ever report a DROP FROM A POSITIVE READ. Read the
  # guard it replaced: `prev_read > 0 and read < prev_read`. Both halves are
  # right for the question "what broke the cache", and together they make the
  # opposite question — "was there ever a cache" — structurally unaskable. A
  # scope whose `cache_read_input_tokens` is 0 on turn 1 and 0 on every turn
  # after never satisfies `prev_read > 0`, so it never renders a verdict, never
  # logs, and never appears in `summary/0`. It reads exactly like a perfectly
  # stable cache.
  #
  # That is not a hypothetical. It is the failure this whole sweep was found
  # through: prompt caching was dead on the OpenRouter route for months and the
  # instrument built to catch precisely that said nothing, because the only
  # thing it could say required the cache to have worked at least once.
  #
  # The extra state is one integer per scope: the number of consecutive turns
  # with a zero read AND an unchanged static prefix. The prefix condition is
  # what keeps this quiet during normal warm-up — a first turn, or a turn after
  # the tool set legitimately changed, has no cache to read from and is not a
  # defect. A prefix that has been byte-stable for `@cold_run_threshold` turns
  # and has still never been read back is.

  # Three turns. Two is a plausible warm-up on a provider that writes on turn 1
  # and reads from turn 2; a stable prefix unread on the third consecutive turn
  # is a configuration fault, not latency.
  @cold_run_threshold 3

  defp next_cold_run(prev, fp, read) do
    cond do
      read > 0 -> 0
      prefix_of(prev) == nil -> 1
      prefix_of(prev) == prefix(fp) -> (cold_run_of(prev) || 0) + 1
      # The prefix genuinely changed, so this turn's miss is explained. Restart
      # the run rather than counting it against the new prefix.
      true -> 1
    end
  end

  defp prefix(%{system: system, tools: tools, model: model}), do: {model, system, tools}
  defp prefix(_), do: nil

  defp prefix_of({fp, _read, _at, _run}), do: prefix(fp)
  defp prefix_of({fp, _read, _at}), do: prefix(fp)
  defp prefix_of(_), do: nil

  defp cold_run_of({_fp, _read, _at, run}) when is_integer(run), do: run
  defp cold_run_of(_), do: 0

  defp report_break(key, prev_fp, fp, prev_read, read, gap_ms, now) do
    verdict = attribute(prev_fp, fp, gap_ms)

    Logger.warning("[PROMPT CACHE] scope=#{key} cache_read #{prev_read} → #{read} — #{verdict}")

    :telemetry.execute(
      [:osa, :prompt_cache, :break],
      %{from: prev_read, to: read},
      %{scope: key, verdict: verdict}
    )

    put_break(key, verdict, now, prev_read, read)
    {:break, verdict}
  end

  defp maybe_report_cold(key, cold_run, read) do
    cond do
      cold_run < @cold_run_threshold ->
        :ok

      # One line per scope at the moment the threshold is crossed, not one per
      # turn thereafter — a warning repeated every turn is one nobody reads,
      # which is how the original loss stayed invisible in the first place.
      rem(cold_run, @cold_run_threshold) != 0 ->
        :ok

      true ->
        verdict =
          "cache_read has been 0 for #{cold_run} consecutive turns with an UNCHANGED static " <>
            "prefix — the prompt cache is not warming at all on this route. Check that the " <>
            "request actually carries cache markers (Anthropic `cache_control`, Bedrock " <>
            "`cachePoint`) and that `prompt_caching_enabled` is on for the path in use."

        Logger.warning("[PROMPT CACHE] scope=#{key} #{verdict}")

        :telemetry.execute(
          [:osa, :prompt_cache, :cold],
          %{turns: cold_run, cache_read: read},
          %{scope: key}
        )

        put_break(key, verdict, System.system_time(:millisecond), 0, 0)
        {:cold, verdict}
    end
  end

  @doc """
  Consecutive turns this scope has reported a zero cache read against an
  unchanged static prefix. `0` means the cache is being read.

  The counterpart to `last_break/1`: that answers "what broke it", this answers
  "was it ever alive".
  """
  @spec cold_run(String.t()) :: non_neg_integer()
  def cold_run(key) when is_binary(key), do: cold_run_of(fetch(key))
  def cold_run(_), do: 0

  @doc """
  Render the verdict for two fingerprints without touching any state.

  `gap_ms` is the wall-clock gap between the two requests, used only to
  distinguish TTL expiry from a server-side miss when the prompt is
  byte-identical.
  """
  @spec attribute(fingerprint(), fingerprint(), non_neg_integer()) :: verdict()
  def attribute(prev, cur, gap_ms) do
    verdicts =
      [
        model_verdict(prev, cur),
        system_verdict(prev, cur),
        tools_verdict(prev, cur),
        cache_control_verdict(prev, cur),
        params_verdict(prev, cur),
        messages_verdict(prev, cur)
      ]
      |> Enum.reject(&is_nil/1)

    case verdicts do
      [] when gap_ms >= @default_ttl_ms -> "possible 5min TTL expiry (prompt unchanged)"
      [] -> "likely server-side (prompt unchanged, <5min gap)"
      list -> Enum.join(list, " · ")
    end
  end

  @doc "Most recent attributed break for a scope, or `nil`."
  @spec last_break(String.t()) ::
          %{verdict: verdict(), at: integer(), from: integer(), to: integer()} | nil
  def last_break(key) when is_binary(key) do
    ensure_table()

    case :ets.lookup(@table, {:break, key}) do
      [{_, report}] -> report
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  All scopes with an attributed break, newest first.

  The readout for `/cost` or `osa doctor`: one line per scope naming what
  broke the cache and by how much.
  """
  @spec summary() :: [%{scope: String.t(), verdict: verdict(), at: integer()}]
  def summary do
    ensure_table()

    @table
    |> :ets.match_object({{:break, :_}, :_})
    |> Enum.map(fn {{:break, key}, report} -> Map.put(report, :scope, key) end)
    |> Enum.sort_by(& &1.at, :desc)
  rescue
    _ -> []
  end

  @doc "Forget a scope (new session / context reset)."
  @spec reset(String.t()) :: :ok
  def reset(key) when is_binary(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ets.delete(@table, {:break, key})
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Verdicts
  # ---------------------------------------------------------------------------

  defp model_verdict(%{model: m}, %{model: m}), do: nil
  defp model_verdict(%{model: a}, %{model: b}), do: "model changed (#{a} → #{b})"

  defp system_verdict(%{system: a}, %{system: b}) when length(a) != length(b),
    do:
      "system prompt changed (+#{max(length(b) - length(a), 0)}/-#{max(length(a) - length(b), 0)} blocks)"

  defp system_verdict(%{system: a}, %{system: b}) do
    n = length(a)

    a
    |> Enum.zip(b)
    |> Enum.with_index(1)
    |> Enum.find_value(fn {{x, y}, i} ->
      if x.hash != y.hash do
        delta = y.len - x.len
        sign = if delta >= 0, do: "+", else: "-"
        "system prompt changed (block #{i}/#{n}, #{sign}#{abs(delta)} chars)"
      end
    end)
  end

  defp tools_verdict(%{tools: a}, %{tools: b}) do
    names_a = Enum.map(a, & &1.name)
    names_b = Enum.map(b, & &1.name)

    added = names_b -- names_a
    removed = names_a -- names_b

    cond do
      added != [] or removed != [] ->
        parts =
          [
            if(added != [], do: "+" <> Enum.join(added, ",")),
            if(removed != [], do: "-" <> Enum.join(removed, ","))
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        "tools changed (+#{length(added)}/-#{length(removed)} tools: #{parts})"

      names_a != names_b ->
        # Same set, different ORDER. The provider hashes the serialized tool
        # array, so a reordering is as fatal as an edit and must be named as
        # its own cause — "schema changed" would send the owner to the wrong file.
        "tools changed (tool order changed, same tool set)"

      true ->
        by_name = Map.new(a, &{&1.name, &1.hash})

        changed =
          b
          |> Enum.filter(fn t -> Map.get(by_name, t.name) != t.hash end)
          |> Enum.map(& &1.name)

        if changed != [] do
          "tools changed (tool prompt/schema changed, same tool set: #{Enum.join(changed, ",")})"
        end
    end
  end

  defp cache_control_verdict(%{system: a, tools: ta}, %{system: b, tools: tb}) do
    a_cc = Enum.map(a, & &1.cc) ++ Enum.map(ta, & &1.cc)
    b_cc = Enum.map(b, & &1.cc) ++ Enum.map(tb, & &1.cc)

    # Only meaningful when the block/tool counts line up; a count change is
    # already reported above and would double-count here.
    if length(a_cc) == length(b_cc) and a_cc != b_cc do
      "cache_control changed (scope or TTL)"
    end
  end

  defp params_verdict(%{params: p}, %{params: p}), do: nil

  defp params_verdict(_, _),
    do: "request params changed (max_tokens/thinking/effort)"

  defp messages_verdict(%{messages: a}, %{messages: b}) do
    n = length(b)

    idx =
      a
      |> Enum.zip(b)
      |> Enum.find_index(fn {x, y} -> x != y end)

    cond do
      # A mutation INSIDE the shared span is the expensive one: everything from
      # that index on re-prefills. Report it in preference to a plain append.
      not is_nil(idx) -> "message history mutated at index #{idx}/#{n}"
      # A pure truncation (history got shorter) also breaks the prefix.
      length(a) > length(b) -> "message history mutated at index #{length(b)}/#{n}"
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Fingerprinting
  # ---------------------------------------------------------------------------

  defp system_fingerprint(nil), do: []
  defp system_fingerprint(""), do: []

  defp system_fingerprint(text) when is_binary(text),
    do: [%{hash: :erlang.phash2(text), len: byte_size(text), cc: nil}]

  defp system_fingerprint(blocks) when is_list(blocks) do
    Enum.map(blocks, fn block ->
      text = to_text(get(block, :text))

      %{
        hash: :erlang.phash2(text),
        len: byte_size(text),
        cc: normalize_cc(get(block, :cache_control))
      }
    end)
  end

  defp system_fingerprint(other), do: system_fingerprint(to_text(other))

  defp tools_fingerprint(nil), do: []

  defp tools_fingerprint(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      name = to_text(get(tool, :name))
      cc = normalize_cc(get(tool, :cache_control))

      # Hash the tool MINUS its name and cache_control, so a schema/description
      # edit is distinguishable from a rename and from a breakpoint move.
      schema = tool |> drop(:name) |> drop(:cache_control)

      %{name: name, hash: :erlang.phash2(schema), cc: cc}
    end)
  end

  defp tools_fingerprint(_), do: []

  defp messages_fingerprint(nil), do: []

  defp messages_fingerprint(messages) when is_list(messages),
    do: Enum.map(messages, &:erlang.phash2/1)

  defp messages_fingerprint(_), do: []

  # Everything not already fingerprinted at finer granularity: max_tokens,
  # thinking, temperature, top_p, stream, and anything a future caller adds.
  defp params_fingerprint(body) do
    body
    |> drop(:model)
    |> drop(:system)
    |> drop(:tools)
    |> drop(:messages)
    |> :erlang.phash2()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, to_string(key))
    end
  end

  defp get(_, _), do: nil

  defp drop(map, key) when is_map(map), do: map |> Map.delete(key) |> Map.delete(to_string(key))
  defp drop(other, _), do: other

  defp to_text(nil), do: ""
  defp to_text(b) when is_binary(b), do: b
  defp to_text(other), do: inspect(other)

  # `%{type: "ephemeral"}` and `%{"type" => "ephemeral"}` are the same wire
  # bytes; a fingerprint that told them apart would report phantom breaks.
  defp normalize_cc(nil), do: nil

  defp normalize_cc(cc) when is_map(cc) do
    Map.new(cc, fn {k, v} ->
      {to_string(k),
       if(is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v), else: v)}
    end)
  end

  defp normalize_cc(other), do: other

  defp cache_read(usage) when is_map(usage) do
    Map.get(usage, :cache_read_input_tokens) || Map.get(usage, "cache_read_input_tokens") || 0
  end

  defp cache_read(_), do: 0

  defp enabled? do
    Application.get_env(:optimal_system_agent, :cache_attribution_enabled, true)
  end

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  defp fetch(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, entry}] -> entry
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp put(key, entry) do
    ensure_table()
    :ets.insert(@table, {key, entry})
    :ok
  rescue
    _ -> :ok
  end

  defp put_break(key, verdict, at, from, to) do
    ensure_table()
    :ets.insert(@table, {{:break, key}, %{verdict: verdict, at: at, from: from, to: to}})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      ref -> ref
    end
  rescue
    ArgumentError -> @table
  end
end
