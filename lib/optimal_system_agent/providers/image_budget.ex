defmodule OptimalSystemAgent.Providers.ImageBudget do
  @moduledoc """
  Image byte-budget eviction with KV-cache hysteresis (request-copy only).

  Keeps the serialized provider request body under the provider's hard size cap
  by evicting the **oldest** inline images first, replacing each with an honest
  text placeholder. A silently-stripped image induces confident hallucination —
  the model "remembers" seeing an image and describes contents that are no longer
  in the request — so the placeholder explicitly tells the model the image is gone
  and not to reason about it from memory.

  ## Why oldest-first + hysteresis

  Eviction rewrites earlier turns, which busts the server-side KV-cache prefix.
  So we do two things to pay that cost as rarely as possible:

    * **Oldest-first / keep-newest** — an image only ever transitions
      `image → placeholder`; a stable prefix never flips `placeholder → image`.
      The prefix only ever shrinks, so the cache stays warm across turns.

    * **Hysteresis** — eviction is *gated* at a high-water trigger
      (`cap - headroom`) but *reclaims* down to a strictly lower low-water mark
      (`cap / 2`). Reclaiming only enough to clear the trigger means the next
      image-bearing turn re-crosses it and evicts again, rewriting the prefix on
      essentially every turn. Dropping to half the cap instead frees a batch of
      headroom, so the prefix is rewritten once and then stays stable for many
      cache-warm turns.

  ## Exact measurement without scanning base64

  `Jason` escape-scans every byte of every string, so encoding the real body
  would walk tens of MB of base64 on every turn. Instead we serialize a copy with
  every image's `data` blanked (cheap: only the small non-image content is
  scanned, and it is measured *exactly*, escaping included) and add back each
  image's raw `data` length. Base64 (`A-Za-z0-9+/=`) contains no JSON-escaped
  characters, so its raw length equals its exact serialized contribution — the
  result is byte-for-byte the true body size.

  ## Scope

  This operates on the **request copy** — the assembled body map handed to the
  HTTP client. It never touches stored session state, reminders, tools, or the
  TUI. When the body is already under the trigger it is a strict no-op and the
  body is returned byte-for-byte unchanged.
  """

  require Logger

  # Phrased so the model treats the image as gone rather than describing it from
  # memory — a silently-stripped image otherwise induces confident hallucination
  # of its contents.
  @placeholder "[An earlier image was removed to keep the request within its size limit and is no longer visible. Do not describe or reason about its contents from memory; ask the user to re-share it if you need to see it again.]"

  # Provider hard request-body ceilings (bytes). Inline base64 image payloads are
  # the dominant term. Defaults are deliberately conservative — the reactive
  # provider error is the final backstop if a cap is ever under-estimated.
  @anthropic_cap 40 * 1024 * 1024
  @google_cap 20 * 1024 * 1024
  @default_cap 40 * 1024 * 1024

  # Headroom below the cap for the parts of the wire request the body
  # measurement cannot perfectly account for (request envelope, sampling params,
  # the small delta between our JSON and the public-API wire format). The bulk of
  # the body — system prompt, messages, tool defs, and image data — is measured
  # exactly, so this only needs to cover sub-MB-to-low-MB of remainder.
  @default_headroom 3 * 1024 * 1024

  @typedoc "Outcome of an eviction pass, surfaced for logging and verification."
  @type outcome :: %{
          evicted: non_neg_integer(),
          images_remaining: non_neg_integer(),
          body_bytes_before: non_neg_integer(),
          body_bytes_after: non_neg_integer(),
          trigger_bytes: non_neg_integer(),
          reclaim_bytes: non_neg_integer()
        }

  @doc """
  The honest placeholder text an evicted image is replaced with.
  """
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @doc """
  Apply image byte-budget eviction to an assembled request body.

  `body` is the map about to be JSON-encoded and sent to the provider (atom-keyed
  envelope, e.g. `%{model: ..., messages: [...]}`; the messages themselves are the
  provider's wire-format string-keyed maps).

  Returns the (possibly modified) body. When the measured body is at or below the
  trigger this is a strict no-op and `body` is returned **unchanged** (same term).

  ## Options

    * `:provider` — `:anthropic` (default cap 40 MB), `:google`/`:gemini`
      (20 MB), or anything else (40 MB). Selects the default cap.
    * `:cap_bytes` — override the provider cap. Also read from app env
      `:image_budget_cap_bytes` when the option is absent.
    * `:headroom_bytes` — headroom below the cap (default 3 MB). The eviction
      trigger is `cap - headroom`.
    * `:trigger_bytes` — override the high-water trigger directly.
    * `:reclaim_bytes` — override the low-water reclaim target (default `cap / 2`).
  """
  @spec apply(map(), keyword()) :: map()
  def apply(body, opts \\ []) when is_map(body) do
    {body, _outcome} = run(body, opts)
    body
  end

  @doc """
  Same as `apply/2` but also returns the `t:outcome/0` for logging/verification.
  """
  @spec run(map(), keyword()) :: {map(), outcome()}
  def run(body, opts \\ []) when is_map(body) do
    {cap, trigger, reclaim} = resolve_thresholds(opts)
    messages = fetch_messages(body)
    before = body_byte_size(body)

    base_outcome = %{
      evicted: 0,
      images_remaining: count_images(messages),
      body_bytes_before: before,
      body_bytes_after: before,
      trigger_bytes: trigger,
      reclaim_bytes: reclaim
    }

    if before <= trigger or messages == [] do
      # No-op: body returned byte-for-byte unchanged.
      {body, base_outcome}
    else
      placeholder_bytes = serialized_bytes(placeholder_block())
      savings = collect_savings(messages, placeholder_bytes)

      k = evict_count(savings, before, reclaim)

      if k == 0 do
        {body, base_outcome}
      else
        {new_messages, _} = evict_messages(messages, k)
        new_body = put_messages(body, new_messages)
        after_bytes = body_byte_size(new_body)

        Logger.info(
          "[image_budget] evicted #{k} oldest image(s): " <>
            "#{before} → #{after_bytes} bytes " <>
            "(cap=#{cap} trigger=#{trigger} reclaim=#{reclaim})"
        )

        outcome = %{
          base_outcome
          | evicted: k,
            images_remaining: count_images(new_messages),
            body_bytes_after: after_bytes
        }

        {new_body, outcome}
      end
    end
  end

  @doc """
  Exact JSON-serialized byte length of the request body — the figure the provider
  weighs against its size cap — computed **without** scanning the multi-MB base64
  image payloads (blank the image data, serialize, add back each raw data length).
  """
  @spec body_byte_size(map()) :: non_neg_integer()
  def body_byte_size(body) when is_map(body) do
    messages = fetch_messages(body)
    {blanked_messages, image_data_bytes} = blank_messages(messages)
    blanked_body = put_messages(body, blanked_messages)
    serialized_bytes(blanked_body) + image_data_bytes
  end

  # ── Capability gate ───────────────────────────────────────────────────────

  @unsupported_prefix "[An image was attached, but the selected model"

  @doc """
  Replace every inline image with an explicit "this model cannot see images"
  note when the catalog says the model takes no image input.

  Dropping an image silently is the worst outcome — the model answers
  confidently about something it never received. Refusing to send it and SAYING
  SO is the next best. When the catalog has no entry for the model (a local or
  unreleased tag) the body is returned unchanged, so the provider's own error is
  what the user sees rather than a guess made here.
  """
  @spec gate_unsupported(map(), atom() | String.t(), String.t() | nil) :: map()
  def gate_unsupported(body, provider, model) when is_map(body) do
    if vision_capable?(provider, model) do
      body
    else
      notice =
        "#{@unsupported_prefix} (#{model}) does not accept image input, so the image was " <>
          "not sent. Do not describe or reason about its contents; tell the user to switch " <>
          "to a vision-capable model or describe the image in text.]"

      messages = fetch_messages(body)

      case replace_all_images(messages, notice) do
        {^messages, 0} ->
          body

        {new_messages, n} ->
          Logger.info("[image_budget] #{n} image(s) not sent: #{provider}/#{model} is text-only")
          put_messages(body, new_messages)
      end
    end
  end

  @doc """
  True when the catalog says `model` accepts image input, or when the catalog
  does not know the model at all (unknown is NOT treated as "cannot").
  """
  @spec vision_capable?(atom() | String.t(), String.t() | nil) :: boolean()
  def vision_capable?(_provider, nil), do: true

  def vision_capable?(provider, model) do
    mods =
      OptimalSystemAgent.Providers.Catalog.modalities(to_string(provider), model) ||
        OptimalSystemAgent.Providers.Catalog.modalities(model)

    case mods do
      %{input: inputs} when is_list(inputs) and inputs != [] ->
        Enum.any?(inputs, &String.contains?(to_string(&1), "image"))

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp replace_all_images(messages, notice) do
    Enum.map_reduce(messages, 0, fn msg, acc ->
      {content, n} = replace_images_in_content(msg_content(msg), notice)
      {put_msg_content(msg, content), acc + n}
    end)
  end

  defp replace_images_in_content(content, notice) when is_list(content) do
    Enum.map_reduce(content, 0, fn block, acc ->
      cond do
        is_binary(image_payload(block)) ->
          {notice_block(block, notice), acc + 1}

        match?(%{"type" => "tool_result", "content" => inner} when is_list(inner), block) ->
          {inner2, n} = replace_images_in_content(Map.get(block, "content"), notice)
          {Map.put(block, "content", inner2), acc + n}

        true ->
          {block, acc}
      end
    end)
  end

  defp replace_images_in_content(other, _notice), do: {other, 0}

  defp notice_block(%{"image" => _}, notice), do: %{"text" => notice}
  defp notice_block(%{"inlineData" => _}, notice), do: %{"text" => notice}
  defp notice_block(_, notice), do: %{"type" => "text", "text" => notice}

  # ── Threshold resolution ──────────────────────────────────────────────────

  defp resolve_thresholds(opts) do
    cap =
      Keyword.get(opts, :cap_bytes) ||
        Application.get_env(:optimal_system_agent, :image_budget_cap_bytes) ||
        cap_for(Keyword.get(opts, :provider))

    headroom = Keyword.get(opts, :headroom_bytes, @default_headroom)
    trigger = Keyword.get(opts, :trigger_bytes, max(cap - headroom, 0))
    reclaim = Keyword.get(opts, :reclaim_bytes, div(cap, 2))

    # Hysteresis invariant: reclaim strictly below trigger, so one batch eviction
    # buys many cache-warm turns instead of re-triggering every turn at the
    # ceiling. Clamp defensively if a caller passes inconsistent overrides.
    reclaim = min(reclaim, trigger)

    {cap, trigger, reclaim}
  end

  defp cap_for(:anthropic), do: @anthropic_cap
  defp cap_for(:google), do: @google_cap
  defp cap_for(:gemini), do: @google_cap
  defp cap_for(_), do: @default_cap

  # ── Body <-> messages access (envelope is atom- or string-keyed) ───────────

  # Gemini's envelope is `contents` with `parts`, not `messages` with `content`.
  # Budgeting only ever looked at `messages`, so a Gemini body was a silent
  # no-op no matter how large its inline images were.
  defp fetch_messages(body) do
    cond do
      is_list(Map.get(body, :messages)) -> Map.get(body, :messages)
      is_list(Map.get(body, "messages")) -> Map.get(body, "messages")
      is_list(Map.get(body, :contents)) -> Map.get(body, :contents)
      is_list(Map.get(body, "contents")) -> Map.get(body, "contents")
      true -> []
    end
  end

  defp put_messages(body, messages) do
    cond do
      Map.has_key?(body, :messages) -> Map.put(body, :messages, messages)
      Map.has_key?(body, "messages") -> Map.put(body, "messages", messages)
      Map.has_key?(body, :contents) -> Map.put(body, :contents, messages)
      Map.has_key?(body, "contents") -> Map.put(body, "contents", messages)
      true -> Map.put(body, :messages, messages)
    end
  end

  defp msg_content(msg) do
    cond do
      Map.has_key?(msg, "content") -> Map.get(msg, "content")
      Map.has_key?(msg, :content) -> Map.get(msg, :content)
      Map.has_key?(msg, "parts") -> Map.get(msg, "parts")
      Map.has_key?(msg, :parts) -> Map.get(msg, :parts)
      true -> nil
    end
  end

  defp put_msg_content(msg, content) do
    cond do
      Map.has_key?(msg, "content") -> Map.put(msg, "content", content)
      Map.has_key?(msg, :content) -> Map.put(msg, :content, content)
      Map.has_key?(msg, "parts") -> Map.put(msg, "parts", content)
      Map.has_key?(msg, :parts) -> Map.put(msg, :parts, content)
      true -> Map.put(msg, "content", content)
    end
  end

  # ── Cross-provider image-block recognition ────────────────────────────────
  #
  # One eviction pass, four wire shapes. Budgeting used to know only Anthropic's
  # `%{"type" => "image", "source" => %{"data" => ..}}`, and it was wired in only
  # at `Anthropic.apply_image_budget/2` — so on every other provider an
  # oversized image request simply failed at the provider instead of degrading.
  @doc false
  @spec image_payload(term()) :: String.t() | nil
  def image_payload(%{"type" => "image", "source" => %{"data" => d}}) when is_binary(d), do: d
  def image_payload(%{type: "image", source: %{data: d}}) when is_binary(d), do: d

  def image_payload(%{"type" => "image_url", "image_url" => %{"url" => "data:" <> _ = u}}), do: u

  def image_payload(%{"image" => %{"source" => %{"bytes" => d}}}) when is_binary(d), do: d
  def image_payload(%{"inlineData" => %{"data" => d}}) when is_binary(d), do: d
  def image_payload(_), do: nil

  # The same block with its payload blanked — used for exact measurement (the
  # raw payload length is added back separately).
  defp blank_image(%{"type" => "image", "source" => src} = b),
    do: Map.put(b, "source", Map.put(src, "data", ""))

  defp blank_image(%{type: "image", source: src} = b),
    do: Map.put(b, :source, Map.put(src, :data, ""))

  defp blank_image(%{"type" => "image_url", "image_url" => iu} = b),
    do: Map.put(b, "image_url", Map.put(iu, "url", ""))

  defp blank_image(%{"image" => %{"source" => src} = img} = b),
    do: Map.put(b, "image", Map.put(img, "source", Map.put(src, "bytes", "")))

  defp blank_image(%{"inlineData" => idata} = b),
    do: Map.put(b, "inlineData", Map.put(idata, "data", ""))

  defp blank_image(b), do: b

  # The placeholder has to be a legal block in the SAME envelope: Anthropic and
  # OpenAI want `%{"type" => "text", "text" => ..}`, Bedrock Converse and Gemini
  # want a bare `%{"text" => ..}`.
  defp placeholder_for(%{"image" => _}), do: %{"text" => @placeholder}
  defp placeholder_for(%{"inlineData" => _}), do: %{"text" => @placeholder}
  defp placeholder_for(_), do: placeholder_block()

  # ── Measurement: blank image data, sum raw lengths ─────────────────────────

  defp blank_messages(messages) do
    Enum.map_reduce(messages, 0, fn msg, acc ->
      {content, sub} = blank_content(msg_content(msg))
      {put_msg_content(msg, content), acc + sub}
    end)
  end

  defp blank_content(content) when is_list(content) do
    Enum.map_reduce(content, 0, fn block, acc ->
      case {image_payload(block), block} do
        {data, _} when is_binary(data) ->
          {blank_image(block), acc + byte_size(data)}

        {_, %{"type" => "tool_result", "content" => inner}} when is_list(inner) ->
          {inner2, sub} = blank_content(inner)
          {Map.put(block, "content", inner2), acc + sub}

        _ ->
          {block, acc}
      end
    end)
  end

  defp blank_content(other), do: {other, 0}

  # ── Image enumeration (document order = oldest-first) ──────────────────────

  defp count_images(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + count_in_content(msg_content(msg)) end)
  end

  defp count_in_content(content) when is_list(content) do
    Enum.reduce(content, 0, fn block, acc ->
      cond do
        is_binary(image_payload(block)) ->
          acc + 1

        match?(%{"type" => "tool_result", "content" => inner} when is_list(inner), block) ->
          acc + count_in_content(Map.get(block, "content"))

        true ->
          acc
      end
    end)
  end

  defp count_in_content(_), do: 0

  # Net body saving per image, in document order (oldest-first). Each entry is
  # `image_part_bytes - placeholder_bytes`, clamped at 0 so evicting a tiny image
  # can never *grow* the running estimate (matches grok's saturating semantics).
  defp collect_savings(messages, placeholder_bytes) do
    Enum.flat_map(messages, fn msg -> savings_in_content(msg_content(msg), placeholder_bytes) end)
  end

  defp savings_in_content(content, placeholder_bytes) when is_list(content) do
    Enum.flat_map(content, fn block ->
      cond do
        is_binary(image_payload(block)) ->
          data = image_payload(block)
          image_bytes = serialized_bytes(blank_image(block)) + byte_size(data)
          [max(image_bytes - placeholder_bytes, 0)]

        match?(%{"type" => "tool_result", "content" => inner} when is_list(inner), block) ->
          savings_in_content(Map.get(block, "content"), placeholder_bytes)

        true ->
          []
      end
    end)
  end

  defp savings_in_content(_, _), do: []

  # How many oldest images to evict: walk oldest→newest subtracting each image's
  # net saving until the running body estimate drops to `target`.
  defp evict_count(savings, current, target) do
    {k, _running} =
      Enum.reduce_while(savings, {0, current}, fn saving, {k, running} ->
        if running <= target do
          {:halt, {k, running}}
        else
          {:cont, {k + 1, running - saving}}
        end
      end)

    k
  end

  # ── Eviction: replace the first K images (document order) with placeholder ──

  defp evict_messages(messages, k) do
    Enum.map_reduce(messages, k, fn msg, left ->
      {content, left2} = evict_content(msg_content(msg), left)
      {put_msg_content(msg, content), left2}
    end)
  end

  defp evict_content(content, left) when is_list(content) do
    Enum.map_reduce(content, left, fn block, l ->
      cond do
        l <= 0 ->
          {block, l}

        is_binary(image_payload(block)) ->
          {placeholder_for(block), l - 1}

        match?(%{"type" => "tool_result", "content" => inner} when is_list(inner), block) ->
          {inner2, l2} = evict_content(Map.get(block, "content"), l)
          {Map.put(block, "content", inner2), l2}

        true ->
          {block, l}
      end
    end)
  end

  defp evict_content(other, left), do: {other, left}

  defp placeholder_block, do: %{"type" => "text", "text" => @placeholder}

  # ── Serialization ─────────────────────────────────────────────────────────

  # Exact JSON byte length via iodata length — no full binary is materialized.
  defp serialized_bytes(term) do
    term
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end
end
