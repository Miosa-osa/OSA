defmodule OptimalSystemAgent.Providers.PromptCache do
  @moduledoc """
  Restructures an outbound request so the cacheable prefix is as LONG as
  possible, for the routes that honour Anthropic-style `cache_control`.

  ## Why this exists

  Anthropic's prompt cache is a strict **prefix** match. A cache breakpoint
  says "everything before this point is one cached segment"; the first byte
  that differs from the previous request ends the reusable prefix, and
  everything after it is re-read at full price no matter how many breakpoints
  follow.

  OSA's system prompt is built as three blocks — static base, world state,
  volatile tail — and the volatile tail (clock, turn count, working tree) sits
  BETWEEN the cached prefix and the conversation. So the conversation could
  never be cached: every turn changed the volatile block, which invalidated
  everything after it. As the transcript grows, that uncached remainder is the
  whole cost.

  This module moves the volatile tail to the END of the message list and puts a
  rolling breakpoint on the LAST HISTORY message. The cached prefix then covers
  tool schemas + system prompt + the entire conversation so far, and only the
  genuinely per-turn bytes fall outside it.

  ## Measured

  Live against OpenRouter → Anthropic on 2026-08-14, `anthropic/claude-haiku-4.5`.

  Replaying ONE real captured OSA request body three times (isolates the wire
  field; no conversation growth):

      arm                                   hit rate   $/turn
      no cache_control (OSA before)             0.0%   $0.033625
      cache_control on system blocks           78.1%   $0.010033
      + volatile moved to tail                  95.0%  $0.004959

  Replaying a real SIX-TURN session in order (the honest agent number, since
  each turn pays a 1.25x write on whatever content is new):

      arm                              hit rate   session cost
      no cache_control (OSA before)        0.0%     $0.176635
      breakpoint after a fixed separator  89.3%     $0.037313
      rolling breakpoint (this module)    93.5%     $0.030768   → 5.74x

  ## Why the breakpoint goes on the last history message

  Position decides whether a segment is reusable at all. A breakpoint placed
  after some fixed separator that TRAILS the history cannot be reused: next
  turn's tool results are inserted before that separator, so the stored segment
  stops being a prefix of the new request. Measured, that pinned the cached
  prefix at 26,213 tokens for six consecutive turns. Marking the last history
  message instead makes turn N's segment a true prefix of turn N+1's request,
  and the cached prefix grows with the transcript (26,213 → 28,297).

  The cost of this is one constraint on the transport: in OpenAI wire format a
  `tool`-role `content` is normally a string, so the marker would be flattened
  away exactly when the last message is a tool result — which in an agent loop
  is most turns. `OpenAICompat.encode_text_preserving_cache/1` keeps the array
  in that one case; verified accepted on the wire.
  """

  require Logger

  alias OptimalSystemAgent.Providers.Registry

  # Marks the message this module appends, so `restructure/3` is idempotent
  # across retry and provider-fallback hops. Never interpolated.
  @tail_marker "## Runtime State"

  # ── The two figures every cache-marking route has to agree on ─────────────

  @doc """
  The global prompt-caching kill switch, `:prompt_caching_enabled` (default
  `true`).

  It lives here rather than in a provider because it names a GLOBAL policy and
  had all five of its call sites inside `Providers.Anthropic`. The polarity
  that produced was inverted in practice: setting it `false` turned caching off
  on the native Anthropic path — the one route that had it — and left it fully
  on for OpenRouter → Anthropic, which is the route the 92.8% hit rate was
  actually measured on. An operator disabling caching (to isolate a billing
  question, or because a gateway mishandles the markers) got the opposite of
  what they asked for on the path that mattered.

  Nothing documented the flag as native-only: its sole prose mention outside
  the source is `docs/roadmap-beat-the-field.md`, which lists
  "`prompt_caching_enabled?` inverse polarity" as a DEFECT. So the behaviour is
  what moved, not the documentation.

  Every route that places a cache marker consults this: `Anthropic`
  (system + tools), `Bedrock` (`cachePoint`), `Registry.normalize_message_content/3`
  (which decides whether marked blocks survive to the OpenAI wire) and
  `restructure/3` below.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :prompt_caching_enabled, true)
  end

  # 4,500 bytes, measured: the default 23-tool array serializes to 33,897 bytes
  # and Anthropic counts it as ~8,267 tokens — 4.1 bytes/token. 4,500 bytes is
  # therefore ~1,100 tokens, just clear of the 1024-token floor below which a
  # breakpoint silently does nothing.
  @min_cacheable_bytes 4_500

  # Bytes/token on this payload shape, from the same measurement. Used only to
  # report an estimate alongside a decision, never to make one.
  @bytes_per_token 4.1

  @doc """
  Minimum serialized bytes a segment must reach before a cache breakpoint is
  worth placing on it.

  ONE number, because there were three. `Anthropic.maybe_add_system/2` used
  4,000 (calibrated against a token count that omitted `input_schema`, so it
  was neither a byte figure nor a token figure), its tools-side sibling was
  recalibrated to 4,500, and `Bedrock` was calibrated to 4,500 independently
  with a comment promising to hold it equal by hand. Three numbers for one
  minimum is how they drift; this is the one they now all read.
  """
  @spec min_cacheable_bytes() :: pos_integer()
  def min_cacheable_bytes, do: @min_cacheable_bytes

  @doc """
  Approximate token count for `bytes` of this payload shape.

  For reporting a decision, never for making one — the decision is a byte
  comparison against `min_cacheable_bytes/0`.
  """
  @spec approx_tokens(non_neg_integer()) :: non_neg_integer()
  def approx_tokens(bytes) when is_integer(bytes) and bytes >= 0,
    do: round(bytes / @bytes_per_token)

  @doc """
  Move the volatile system tail to the end of `messages` and mark the resulting
  stable prefix with a cache breakpoint.

  Returns `messages` unchanged unless ALL of these hold:

    * the route honours `cache_control` (`Registry.anthropic_prompt_cache?/2`);
    * the leading system message carries block-shaped content with at least one
      `cache_control` marker (i.e. `Agent.Context` built the cached split);
    * there is an unmarked volatile tail to move.

  Idempotent: re-entry through a retry or a provider fallback hop is a no-op,
  because the separator it looks for is the one it appends.
  """
  @spec restructure(list(), module() | {:compat, atom()}, keyword()) :: list()
  def restructure(messages, target, opts \\ [])

  def restructure(messages, target, opts) when is_list(messages) and messages != [] do
    # `Registry.resolved_model/2`, NOT `Keyword.get(opts, :model)`.
    #
    # `anthropic_prompt_cache?/2` guards on `is_binary(model)` and falls to
    # `false` for nil, and `opts[:model]` is nil on every non-CLI entry point.
    # `resolved_model/2` exists to close exactly that hole and its own docstring
    # says so — but the fix was applied at `Registry.normalize_message_content/3`
    # (registry.ex:699) and not here, 600 lines away in the same pipeline, so
    # the two stages of one cache strategy disagreed about which model the
    # request is for.
    #
    # The failure is partial, which is why it survived: the system-block
    # `cache_control` breakpoints still land (that stage resolves the model), so
    # the wire body looks cached. What is skipped is the volatile-tail
    # relocation and the rolling history breakpoint — by this module's own
    # measured table, the difference between the 95.0%/93.5% arm and the
    # 78.1%/89.3% one. A partial win reads as a working cache.
    #
    # Reachable on every caller that does not name a model: `Agent.Compactor`
    # (the largest payloads in the system), the classifier, keeper, weaver,
    # dream and workflow callers, and EVERY provider-fallback hop —
    # `cross_provider_opts/1` drops `:model` deliberately.
    # `enabled?/0` FIRST, and as a real gate rather than a comment: this module
    # places a `cache_control` breakpoint on the last history message, so an
    # operator who turned prompt caching off and still saw markers on the wire
    # was looking at this function. See `enabled?/0` for why the flag is global.
    if enabled?() and applies?(target) and
         Registry.anthropic_prompt_cache?(target, Registry.resolved_model(target, opts)) and
         not already_restructured?(messages) do
      do_restructure(messages)
    else
      report_skip(messages, target, opts)
    end
  end

  def restructure(messages, _target, _opts), do: messages

  # A skipped restructure is a cache decision, and until now it was an
  # invisible one: the messages came back byte-identical and nothing recorded
  # that the rolling breakpoint — worth ~16 points of hit rate by this module's
  # own measured table — had not been placed. Telemetry always; a LOG only for
  # the arm an operator can act on (the kill switch), deduped per process so a
  # steady-state session says it once rather than once per turn.
  defp report_skip(messages, target, opts) do
    reason =
      cond do
        not enabled?() -> :disabled_by_config
        not applies?(target) -> :transport_not_supported
        already_restructured?(messages) -> :already_restructured
        true -> :route_not_anthropic_cached
      end

    :telemetry.execute(
      [:osa, :prompt_cache, :restructure_skipped],
      %{message_count: length(messages)},
      %{reason: reason, target: target, model: Registry.resolved_model(target, opts)}
    )

    if reason == :disabled_by_config and Process.get(:osa_prompt_cache_off) != true do
      Process.put(:osa_prompt_cache_off, true)

      Logger.info(
        "[PromptCache] prompt caching is disabled by config — no cache_control breakpoints " <>
          "will be placed on ANY route, and cache_read_input_tokens will stay 0."
      )
    end

    messages
  rescue
    # Telemetry on a hot path must never be able to fail the request.
    _ -> messages
  end

  # DELIBERATELY limited to the OpenAI-compatible transport, which is the only
  # one this was measured on (OpenRouter → Anthropic, live, 2026-08-14).
  #
  # The native Anthropic path already emits `cache_control` system blocks and
  # its own tools breakpoint, so it is not broken — it is just leaving the
  # conversation segment uncached, the same ~16 points this module recovers
  # here. Extending it there is worth doing and should be easy, but it changes
  # message shape on a path no test in this repo exercises against a real
  # provider, and there is no Anthropic API key on this machine to verify it
  # with. Shipping an unverified change to the primary provider to chase a win
  # nobody has measured is how the last cache "fix" ended up believed rather
  # than true.
  defp applies?({:compat, _provider}), do: true
  defp applies?(_target), do: false

  defp already_restructured?(messages) do
    Enum.any?(messages, fn msg ->
      case content_of(msg) do
        parts when is_list(parts) ->
          Enum.any?(parts, &String.starts_with?(text_of(&1) || "", @tail_marker))

        _ ->
          false
      end
    end)
  end

  defp do_restructure([first | rest] = messages) do
    with parts when is_list(parts) <- content_of(first),
         true <- Enum.any?(parts, &marked?/1),
         # Everything up to and including the LAST marked block is the stable
         # prefix; whatever trails it unmarked is the volatile tail.
         last_marked when last_marked >= 0 <- last_marked_index(parts),
         {keep, tail} <- Enum.split(parts, last_marked + 1),
         volatile when volatile != "" <- join_text(tail),
         [_ | _] = history <- rest do
      # The rolling breakpoint goes on the LAST HISTORY message, with the
      # volatile tail appended AFTER it and left unmarked.
      #
      # Position is the whole point. A breakpoint placed after some fixed
      # separator text that trails the history cannot be reused, because next
      # turn's new tool results are inserted BEFORE that separator — so the
      # stored segment is no longer a prefix of the new request. MEASURED: with
      # the separator the cached prefix stayed pinned at 26,213 tokens for six
      # straight turns; with the breakpoint on the last history message it grew
      # 26,213 → 28,297 and the session got another 21% cheaper.
      trailing = %{role: "user", content: [%{type: "text", text: @tail_marker <> "\n" <> volatile}]}

      marked_history = List.update_at(history, -1, &mark_last_part/1)

      [put_content(first, keep) | marked_history] ++ [trailing]
    else
      _ -> messages
    end
  end

  defp do_restructure(messages), do: messages

  # Put the breakpoint on the final content part of a message, promoting string
  # content to a one-part array. `OpenAICompat.encode_text_preserving_cache/1`
  # keeps that array intact for `tool` and `assistant` turns, which would
  # otherwise be flattened back to a string and lose the marker.
  defp mark_last_part(msg) do
    parts =
      case content_of(msg) do
        c when is_binary(c) and c != "" -> [%{type: "text", text: c}]
        c when is_list(c) and c != [] -> c
        _ -> nil
      end

    case parts do
      nil -> msg
      ps -> put_content(msg, List.update_at(ps, -1, &put_marker/1))
    end
  end

  defp put_marker(%{"text" => _} = p), do: Map.put(p, "cache_control", %{"type" => "ephemeral"})
  defp put_marker(p) when is_map(p), do: Map.put(p, :cache_control, %{type: "ephemeral"})
  defp put_marker(p) when is_binary(p), do: %{type: "text", text: p, cache_control: %{type: "ephemeral"}}
  defp put_marker(p), do: p

  defp last_marked_index(parts) do
    parts
    |> Enum.with_index()
    |> Enum.filter(fn {p, _i} -> marked?(p) end)
    |> List.last()
    |> case do
      {_p, i} -> i
      nil -> -1
    end
  end

  defp join_text(parts) do
    parts
    |> Enum.map(&text_of/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp marked?(%{cache_control: cc}) when not is_nil(cc), do: true
  defp marked?(%{"cache_control" => cc}) when not is_nil(cc), do: true
  defp marked?(_), do: false

  defp text_of(%{text: t}) when is_binary(t), do: t
  defp text_of(%{"text" => t}) when is_binary(t), do: t
  defp text_of(t) when is_binary(t), do: t
  defp text_of(_), do: nil

  defp content_of(%{content: c}), do: c
  defp content_of(%{"content" => c}), do: c
  defp content_of(_), do: nil

  defp put_content(%{content: _} = msg, c), do: %{msg | content: c}
  defp put_content(%{"content" => _} = msg, c), do: Map.put(msg, "content", c)
  defp put_content(msg, _c), do: msg
end
