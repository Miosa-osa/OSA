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
  @bedrock_cap 20 * 1024 * 1024
  @compat_cap 20 * 1024 * 1024
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

    * `:provider` — selects the default cap via `cap_for/1`, which has an entry
      per provider (Anthropic 40 MB, Google/Bedrock 20 MB, compat gateways
      20 MB). A provider with no entry still gets 40 MB but is REPORTED, so a
      missing entry is visible rather than inherited.
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
    {capable?, source} = vision_decision(provider, model)
    report_vision(provider, model, capable?, source)

    if capable? do
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
          Logger.warning(
            "[image_budget] #{n} image(s) NOT sent: #{provider}/#{model} does not accept " <>
              "image input (#{source}). The model is told so explicitly rather than being " <>
              "left to answer from memory."
          )

          put_messages(body, new_messages)
      end
    end
  end

  # The vision gate could only ever answer `true` for Bedrock, the CLI providers
  # and every gateway, and it never said which authority it had asked. Both the
  # answer and its source are now on the wire next to `effort` and `reasoning`.
  defp report_vision(provider, model, capable?, source) do
    :telemetry.execute(
      [:osa, :image_budget, :vision],
      %{capable: if(capable?, do: 1, else: 0)},
      %{provider: provider, model: model, source: source, capable: capable?}
    )

    key = {provider, model, capable?, source}

    if Process.get(:osa_image_budget_vision) != key do
      Process.put(:osa_image_budget_vision, key)

      # `:unknown_default` is the fail-open arm — the one that used to be the
      # ONLY arm for most providers. It is the interesting case, so it is the
      # one that gets a line rather than the confident answers.
      if source == :unknown_default do
        Logger.info(
          "[image_budget] no vision data for #{provider}/#{model} in either catalogue; " <>
            "assuming it accepts images (fail-open). If it does not, the provider's own " <>
            "error is what you will see."
        )
      end
    end

    :ok
  end

  @doc """
  True when either authority says `model` accepts image input, or when neither
  knows the model at all (unknown is NOT treated as "cannot").

  See `vision_decision/2` for which authority answered and why.
  """
  @spec vision_capable?(atom() | String.t(), String.t() | nil) :: boolean()
  def vision_capable?(provider, model) do
    {capable?, _source} = vision_decision(provider, model)
    capable?
  end

  @doc """
  Whether `model` takes image input, and WHICH authority said so.

  `{boolean, :no_model | :osa_catalogue | :upstream_catalog | :unknown_default}`.

  ## Two authorities, and why the second one was dead

  OSA ships its own `:vision` flag on every entry of four catalogues —
  `AnthropicModels`, `OpenAIModels`, `GoogleModels`, `OllamaCloud` — reached
  through each module's `capability(id, :vision)`. **Nothing called it.** This
  function consulted only the bundled third-party `Providers.Catalog`, and it
  looked that up under `to_string(provider)` — but that catalog's provider ids
  are `anthropic cerebras cohere deepseek fireworks google groq hyperbolic
  mistral openai perplexity sambanova together xai`. It has no `bedrock`, no
  `ollama_cloud`, no `claude_cli`, no `openrouter`, no `ollama`. Every one of
  those providers missed on the keyed lookup, missed again on the cross-provider
  `find/1` (Bedrock's ids carry a `us.` profile prefix and a `-v1:0` suffix that
  match nothing upstream), and fell through to the `true` default.

  So: 39 hand-maintained `vision:` flags that no code path could read, and a
  gate that answered `true` for every provider OSA added after the two the
  lookup was written for.

  ## Delete them or wire them?

  **Wired**, not deleted, and only in the POSITIVE-and-negative direction where
  OSA's own catalogue has an entry — because the fail-open default is documented
  and deliberate (a model the catalog does not know must not lose its images),
  but "the catalog does not know" was never the situation for these models. OSA
  *did* know; the answer was simply unreachable. Deleting the flags would have
  locked in the fail-open for the models OSA has first-hand data on, which is
  the wrong half to keep: fail-open exists to cover ignorance, not to override
  knowledge.

  The upstream catalog stays as the second authority for the providers it does
  cover, and `:unknown_default` remains `true` for everything neither knows.
  """
  @spec vision_decision(atom() | String.t(), String.t() | nil) :: {boolean(), atom()}
  def vision_decision(_provider, nil), do: {true, :no_model}

  def vision_decision(provider, model) do
    case osa_catalogue_vision(provider, model) do
      capable? when is_boolean(capable?) ->
        {capable?, :osa_catalogue}

      nil ->
        case upstream_vision(provider, model) do
          capable? when is_boolean(capable?) -> {capable?, :upstream_catalog}
          nil -> {true, :unknown_default}
        end
    end
  rescue
    _ -> {true, :unknown_default}
  end

  # Which of OSA's own catalogues speaks for this provider. Bedrock serves
  # Anthropic models under a profile-prefixed id, and `claude_cli` is Anthropic
  # by definition — both were previously looked up under a provider key that
  # does not exist anywhere, which is the whole reason they answered nothing.
  defp vision_catalogues(provider) do
    alias OptimalSystemAgent.Providers.AnthropicModels
    alias OptimalSystemAgent.Providers.GoogleModels
    alias OptimalSystemAgent.Providers.OllamaCloud
    alias OptimalSystemAgent.Providers.OpenAIModels

    case provider do
      p when p in [:anthropic, :claude_cli, :bedrock, "anthropic", "claude_cli", "bedrock"] ->
        [AnthropicModels]

      p
      when p in [:openai, :openai_codex, :copilot_cli, "openai", "openai_codex", "copilot_cli"] ->
        [OpenAIModels]

      p when p in [:google, :gemini, :vertex, "google", "gemini", "vertex"] ->
        [GoogleModels]

      p when p in [:ollama_cloud, :ollama, "ollama_cloud", "ollama"] ->
        [OllamaCloud]

      # A gateway serves every vendor, so all four are candidates and the first
      # that recognises the id answers. This is a union, never a veto: a
      # catalogue that does not know the model returns nil and the next one is
      # asked.
      _ ->
        [AnthropicModels, OpenAIModels, GoogleModels, OllamaCloud]
    end
  end

  # `Enum.find_value/2` is WRONG here and was written that way first: it stops on
  # the first TRUTHY result, so a catalogue answering `false` — the only answer
  # that changes anything, and the only reason `vision: false` exists in
  # `OllamaCloud` at all — is indistinguishable from "this catalogue does not
  # know the model" and the search runs on to the fail-open default. That is
  # this file's own defect shape, so it is spelled out rather than made terse:
  # the search is for an ANSWER, and `false` is an answer.
  defp osa_catalogue_vision(provider, model) do
    ids = candidate_ids(model)

    Enum.reduce_while(vision_catalogues(provider), nil, fn mod, _acc ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :capability, 2) do
        case first_boolean(ids, mod) do
          nil -> {:cont, nil}
          answer -> {:halt, answer}
        end
      else
        {:cont, nil}
      end
    end)
  end

  defp first_boolean(ids, mod) do
    Enum.reduce_while(ids, nil, fn id, _acc ->
      case mod.capability(id, :vision) do
        v when is_boolean(v) -> {:halt, v}
        _ -> {:cont, nil}
      end
    end)
  end

  # Bedrock names the same Anthropic model `us.anthropic.claude-sonnet-4-5-…-v1:0`
  # and a gateway names it `anthropic/claude-sonnet-4-5`. The catalogues are keyed
  # on the bare vendor id, so the wrapping is stripped before asking.
  defp candidate_ids(model) do
    bare =
      model
      |> String.split("/")
      |> List.last()
      |> String.replace(~r/^(us|eu|apac|global)\./, "")
      |> String.replace(~r/^(anthropic|amazon|meta|mistral|cohere|ai21|deepseek)\./, "")
      |> String.replace(~r/-v\d+:\d+$/, "")

    # `claude-sonnet-4-5-20250929` → `claude-sonnet-4-5`. The catalogues key on
    # the undated family id and resolve dated snapshots by prefix, but only
    # after the Bedrock wrapping is off — so the strip has to happen here.
    undated = String.replace(bare, ~r/-\d{8}$/, "")

    Enum.uniq([model, bare, undated])
  end

  defp upstream_vision(provider, model) do
    mods =
      OptimalSystemAgent.Providers.Catalog.modalities(to_string(provider), model) ||
        OptimalSystemAgent.Providers.Catalog.modalities(model)

    case mods do
      %{input: inputs} when is_list(inputs) and inputs != [] ->
        Enum.any?(inputs, &String.contains?(to_string(&1), "image"))

      _ ->
        nil
    end
  end

  defp replace_all_images(messages, notice) do
    Enum.map_reduce(messages, 0, fn msg, acc ->
      {content, n} = replace_images_in_content(msg_content(msg), notice)
      msg = put_msg_content(msg, content)

      case msg_images(msg) do
        [] ->
          {msg, acc + n}

        siblings ->
          {msg |> put_msg_images([]) |> append_placeholder_text(notice),
           acc + n + length(siblings)}
      end
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
        elem(cap_for(Keyword.get(opts, :provider)), 0)

    headroom = Keyword.get(opts, :headroom_bytes, @default_headroom)
    trigger = Keyword.get(opts, :trigger_bytes, max(cap - headroom, 0))
    reclaim = Keyword.get(opts, :reclaim_bytes, div(cap, 2))

    # Hysteresis invariant: reclaim strictly below trigger, so one batch eviction
    # buys many cache-warm turns instead of re-triggering every turn at the
    # ceiling. Clamp defensively if a caller passes inconsistent overrides.
    reclaim = min(reclaim, trigger)

    {cap, trigger, reclaim}
  end

  @doc """
  The request-body ceiling assumed for `provider`, and the authority for it.

  `{bytes, :provider_table | :compat_default | :unknown_provider}`.

  ## Why this is not three clauses any more

  It was `:anthropic | :google | :gemini | _`, so **every other provider fell to
  40 MB** — Bedrock, and all ~19 gateways routed through `OpenAICompat`. Two of
  those are documented lower than 40 MB, which means the eviction trigger
  (`cap - headroom` = 37 MB) sat *above* the provider's own hard limit and the
  guard could never fire before the request was rejected. Same shape as the rest
  of this sweep: a table correct for the two providers it was written against,
  applied as the answer for every provider.

  The `:unknown_provider` arm still answers 40 MB — an invented low cap would
  evict images a provider would have accepted, which is the worse error — but it
  now SAYS SO once per provider, so a new provider's missing entry is visible
  rather than inherited silently.
  """
  @spec cap_for(atom() | String.t() | nil) :: {pos_integer(), atom()}
  def cap_for(:anthropic), do: {@anthropic_cap, :provider_table}
  def cap_for(:google), do: {@google_cap, :provider_table}
  def cap_for(:gemini), do: {@google_cap, :provider_table}
  def cap_for(:vertex), do: {@google_cap, :provider_table}

  # AWS documents a 25 MB ceiling on a Converse request payload (and a smaller
  # per-image limit inside it). 20 MB is that figure with headroom, and is not
  # verified against a live Bedrock call — no Bedrock credential exists here.
  def cap_for(:bedrock), do: {@bedrock_cap, :provider_table}

  # Local servers, bounded by the operator's own machine rather than a vendor
  # limit. Listed explicitly so they are not reported as unknown every turn.
  def cap_for(:ollama), do: {@default_cap, :provider_table}
  def cap_for(:ollama_cloud), do: {@default_cap, :provider_table}
  def cap_for(:claude_cli), do: {@anthropic_cap, :provider_table}
  def cap_for(:copilot_cli), do: {@default_cap, :provider_table}
  def cap_for(:openai), do: {@default_cap, :provider_table}
  def cap_for(:openai_codex), do: {@default_cap, :provider_table}

  def cap_for(provider) when is_atom(provider) and not is_nil(provider) do
    if compat_routed?(provider) do
      # No gateway publishes its own body ceiling, and every one of them proxies
      # to an upstream vendor. 20 MB is the smallest documented upstream cap
      # (Google's), so it is the only bound that holds whatever the gateway
      # forwards to.
      {@compat_cap, :compat_default}
    else
      report_unknown_cap(provider)
      {@default_cap, :unknown_provider}
    end
  end

  def cap_for(provider) when is_binary(provider) do
    case Enum.find(known_provider_atoms(), &(to_string(&1) == provider)) do
      nil ->
        report_unknown_cap(provider)
        {@default_cap, :unknown_provider}

      atom ->
        cap_for(atom)
    end
  end

  def cap_for(_), do: {@default_cap, :unknown_provider}

  defp known_provider_atoms do
    [
      :anthropic,
      :google,
      :gemini,
      :vertex,
      :bedrock,
      :ollama,
      :ollama_cloud,
      :claude_cli,
      :copilot_cli,
      :openai,
      :openai_codex
    ] ++ compat_providers()
  end

  defp compat_routed?(provider), do: provider in compat_providers()

  defp compat_providers do
    OptimalSystemAgent.Providers.Registry.compat_providers()
  rescue
    _ -> []
  end

  defp report_unknown_cap(provider) do
    :telemetry.execute(
      [:osa, :image_budget, :cap],
      %{cap_bytes: @default_cap},
      %{provider: provider, source: :unknown_provider}
    )

    key = {:unknown_cap, provider}

    if Process.get(:osa_image_budget_cap) != key do
      Process.put(:osa_image_budget_cap, key)

      Logger.info(
        "[image_budget] no request-size cap known for provider #{inspect(provider)}; " <>
          "assuming #{@default_cap} bytes. If this provider's real ceiling is lower, the " <>
          "eviction guard cannot fire before the provider rejects the request — add it to " <>
          "ImageBudget.cap_for/1."
      )
    end

    :ok
  end

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

  # ── Ollama: images are a SIBLING of content, not a block inside it ─────────
  #
  # `%{"role" => "user", "content" => "…", "images" => ["<bare base64>", …]}`.
  # Every traversal in this module reaches images through `msg_content/1`, which
  # for an Ollama message returns a plain STRING — so `blank_content/1`,
  # `count_in_content/1`, `savings_in_content/2` and `evict_content/2` all fell
  # to their `(other)` clauses and returned zero. Ollama gained a working image
  # path (`Ollama.encode_content/1`) and this module reported `images_remaining:
  # 0` and `body_bytes_before` short by the entire payload, for every one of
  # them. The counters were not wrong about a number; they were describing a
  # different message than the one being sent.
  #
  # These are the only images that do not live in a content LIST, which is why
  # they need their own axis rather than another `image_payload/1` clause.
  @doc false
  @spec msg_images(term()) :: [String.t()]
  def msg_images(msg) when is_map(msg) do
    case Map.get(msg, "images") || Map.get(msg, :images) do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  def msg_images(_), do: []

  defp put_msg_images(msg, []) do
    msg |> Map.delete("images") |> Map.delete(:images)
  end

  defp put_msg_images(msg, images) do
    if Map.has_key?(msg, :images),
      do: Map.put(msg, :images, images),
      else: Map.put(msg, "images", images)
  end

  # An Ollama message's content is a plain string, so an evicted sibling image
  # has nowhere to leave a block behind — the placeholder is appended to the
  # text instead. Saying nothing here is the failure this module exists to
  # prevent: the model would still see the earlier turn's prose and no image.
  defp append_placeholder_text(msg, text) do
    prev = to_string(msg_content(msg) || "")
    joined = if prev == "", do: text, else: prev <> "\n\n" <> text
    put_msg_content(msg, joined)
  end

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
      siblings = msg_images(msg)
      sibling_bytes = Enum.reduce(siblings, 0, &(byte_size(&1) + &2))

      blanked =
        msg
        |> put_msg_content(content)
        |> then(fn m ->
          if siblings == [], do: m, else: put_msg_images(m, Enum.map(siblings, fn _ -> "" end))
        end)

      {blanked, acc + sub + sibling_bytes}
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
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + count_in_content(msg_content(msg)) + length(msg_images(msg))
    end)
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
    Enum.flat_map(messages, fn msg ->
      savings_in_content(msg_content(msg), placeholder_bytes) ++
        sibling_savings(msg, placeholder_bytes)
    end)
  end

  # An Ollama sibling image contributes its raw base64 length plus the two bytes
  # of `""` quoting in the array. The placeholder replaces it with text in the
  # content string, so the same `max(.. - placeholder, 0)` clamp applies.
  defp sibling_savings(msg, placeholder_bytes) do
    msg
    |> msg_images()
    |> Enum.map(fn data -> max(byte_size(data) + 2 - placeholder_bytes, 0) end)
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
      # Same order `collect_savings/2` walks in: content blocks, then the
      # sibling `images` array. A mismatch here would evict a different set than
      # the one the count was computed from.
      {content, left2} = evict_content(msg_content(msg), left)
      evict_siblings(put_msg_content(msg, content), left2)
    end)
  end

  defp evict_siblings(msg, left) do
    case msg_images(msg) do
      [] ->
        {msg, left}

      images ->
        {kept, remaining, dropped} =
          Enum.reduce(images, {[], left, 0}, fn data, {kept, l, dropped} ->
            if l > 0, do: {kept, l - 1, dropped + 1}, else: {[data | kept], l, dropped}
          end)

        if dropped == 0 do
          {msg, remaining}
        else
          msg =
            msg
            |> put_msg_images(Enum.reverse(kept))
            |> append_placeholder_text(@placeholder)

          {msg, remaining}
        end
    end
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
