defmodule OptimalSystemAgent.Memory.SessionTitler do
  @moduledoc """
  Session auto-titling — the self-contained idea adopted from opencode 2.0.

  opencode generates a short, human-readable title for every conversation so
  users can find past sessions at a glance (see its `agent/prompt/title.txt`).
  OSA already had AGENTS.md/project-context discovery (`Agent.ContextDiscovery`)
  and file-backed custom commands (`Tools.Registry.CommandLoader`), so those
  opencode ideas were NOT missing. Session titling *was* missing and is the most
  self-contained + valuable remaining option: a small, LLM-summarization feature
  that lives entirely in the memory area, reuses the existing provider registry,
  and has a pure, testable core.

  The title-generation rules are ported from opencode's title prompt: a single
  line, <= #{60} chars, no tool names, keep technical terms/filenames/numbers,
  drop filler words, never refuse.

  Titles are persisted to `~/.osa/session_titles.json` (a `{session_id => title}`
  map). This keeps the feature dependency-free — no schema migration.

  ## Two-stage titling

  A title that only appears after the first reply is useless precisely when you
  need it — scanning a picker for the session you want. So titling is staged:

    1. **Immediate, synchronous, pure.** `ensure_title/2` derives a title from the
       user's opening message with `from_message/1` (no network, microseconds) and
       stores it *before the turn runs*. Every session therefore has a title from
       the moment it starts.
    2. **Deferred, asynchronous, best-effort.** The same call spawns an LLM
       refinement on `OptimalSystemAgent.TaskSupervisor`. If it succeeds the
       heuristic title is upgraded in place; if it fails, times out, or the
       provider is unreachable, the heuristic title simply stands.

  Stage 2 is fire-and-forget on a supervised, temporary child: it cannot block,
  slow, or fail the turn.

  ## Title precedence

  `display_title/2` resolves in this order, so an automatic title never clobbers
  something the user chose:

    1. a manual title set via `/rename` (`Agent.SessionPersistence` metadata)
    2. the automatic title in `session_titles.json`
    3. the caller's fallback (first message / bare session id)

  ## Model selection

  The refinement call runs on a *small* model resolved from the live provider
  catalog (`Providers.Catalog.small_model/1` — models.dev data, refreshed and
  cached), never a hardcoded model id. Hardcoded ids age out; the catalog does
  not. When the catalog cannot name one, the call falls back to the session's
  normal model rather than failing.
  """

  require Logger

  alias OptimalSystemAgent.Store.SessionTranscript
  alias OptimalSystemAgent.Providers.Catalog
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @max_title_chars 60
  @max_input_chars 2_000

  @system_prompt """
  You are a title generator. You output ONLY a thread title. Nothing else.

  Generate a brief title that would help the user find this conversation later.

  Rules:
  - A single line, <= #{@max_title_chars} characters, no surrounding quotes.
  - Grammatically correct and natural — no word salad.
  - Never include tool names (e.g. "read tool", "bash tool", "edit tool").
  - Focus on the main topic or task the user needs to retrieve.
  - Keep exact: technical terms, numbers, filenames, HTTP codes.
  - Remove filler words: the, this, my, a, an.
  - Never assume a tech stack; never respond to the question — only title it.
  - Never refuse or complain about the input; always output something meaningful.
  - If the message is short/conversational ("hello", "lol"), title the intent
    (e.g. "Greeting", "Quick check-in").

  Examples:
  "debug 500 errors in production" -> Debugging production 500 errors
  "refactor user service" -> Refactoring user service
  "why is app.js failing" -> app.js failure investigation
  "implement rate limiting" -> Rate limiting implementation
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate (and persist) a title for `session_id`.

  Loads the session transcript, extracts the first user message, asks the model
  for a title, sanitizes it, stores it, and returns `{:ok, title}`.

  Options:
    * `:chat_fun` — `fn system, user -> {:ok, String.t()} | {:error, term()} end`
      (default: real LLM call). Injected for tests.
    * `:persist` — whether to write the title to disk (default: `true`).

  Returns `{:ok, title}` or `{:error, reason}` (e.g. `:no_content`).
  """
  @spec title_for(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def title_for(session_id, opts \\ []) when is_binary(session_id) do
    chat_fun = Keyword.get(opts, :chat_fun, &default_chat/2)
    persist? = Keyword.get(opts, :persist, true)

    with {:ok, user_text} <- first_user_text(session_id),
         {system, user} = build_prompt(user_text),
         {:ok, raw} <- chat_fun.(system, user),
         title when title != "" <- sanitize_title(raw) do
      if persist?, do: put_title(session_id, title)
      {:ok, title}
    else
      {:error, reason} -> {:error, reason}
      "" -> {:error, :empty_title}
      other -> {:error, other}
    end
  end

  @doc """
  Give `session_id` a title *now*, from the user's opening `message`.

  Stage 1 (synchronous, pure) stores `from_message/1` immediately, so the session
  is never listed untitled. Stage 2 spawns an LLM refinement that upgrades it in
  place if and when it succeeds.

  A no-op when the session already has a title (automatic or manual), so only the
  opening message titles a session and `/rename` is never overwritten.

  Always returns `:ok`. This runs on the turn's hot path, so every failure mode —
  no supervisor, unreachable provider, unwritable config dir — degrades to
  "keep whatever title we have" and never propagates.

  Options:
    * `:refine` — run stage 2 (default: `true`; set `false` in tests)
    * `:chat_fun` — injected into stage 2, see `title_for/2`
  """
  @spec ensure_title(String.t(), String.t(), keyword()) :: :ok
  def ensure_title(session_id, message, opts \\ [])

  def ensure_title(session_id, message, opts)
      when is_binary(session_id) and is_binary(message) do
    if has_title?(session_id) do
      :ok
    else
      case from_message(message) do
        "" ->
          :ok

        seed ->
          put_title(session_id, seed)
          broadcast_title(session_id, seed)
          if Keyword.get(opts, :refine, true), do: refine_async(session_id, opts)
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def ensure_title(_session_id, _message, _opts), do: :ok

  @doc """
  Derive an immediate title from a user message — pure, no network.

  This is the stage-1 seed: the same cleanup rules as `sanitize_title/1` (first
  line, no labels/quotes, collapsed whitespace, <= #{@max_title_chars} chars on a
  word boundary) plus list/quote/heading marker stripping and a capitalized first
  letter, since a raw prompt is usually lowercase.
  """
  @spec from_message(String.t()) :: String.t()
  def from_message(message) when is_binary(message) do
    message
    |> first_nonempty_line()
    |> strip_leading_markers()
    |> sanitize_title()
    |> capitalize_first()
  end

  def from_message(_), do: ""

  @doc """
  The title to show for `session_id`: manual (`/rename`) beats automatic beats
  `fallback`. Never raises; returns `fallback` if every lookup fails.
  """
  @spec display_title(String.t(), String.t() | nil) :: String.t() | nil
  def display_title(session_id, fallback \\ nil) when is_binary(session_id) do
    manual_title(session_id) || get_title(session_id) || fallback
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end

  @doc """
  Resolve display titles for many sessions in one pass.

  `list_sessions/1`-shaped rows go in, the same rows with a `:title` go out. Reads
  both title stores once instead of once per row, so a 500-session listing does
  not do 1000 file reads.
  """
  @spec decorate_rows([map()], atom()) :: [map()]
  def decorate_rows(rows, id_key \\ :session_id) when is_list(rows) do
    auto = titles()

    Enum.map(rows, fn row ->
      case Map.get(row, id_key) do
        id when is_binary(id) ->
          Map.put(row, :title, manual_title(id) || Map.get(auto, id))

        _ ->
          Map.put_new(row, :title, nil)
      end
    end)
  rescue
    _ -> rows
  catch
    _, _ -> rows
  end

  @doc "Return the stored title for `session_id`, or `nil`."
  @spec get_title(String.t()) :: String.t() | nil
  def get_title(session_id) do
    titles() |> Map.get(session_id)
  end

  @doc "Return the full `{session_id => title}` map."
  @spec titles() :: %{optional(String.t()) => String.t()}
  def titles do
    with {:ok, body} <- File.read(titles_file()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  @doc "Persist `title` for `session_id`."
  @spec put_title(String.t(), String.t()) :: :ok
  def put_title(session_id, title) do
    file = titles_file()
    File.mkdir_p(Path.dirname(file))
    updated = titles() |> Map.put(session_id, title)
    File.write(file, Jason.encode!(updated))
    :ok
  rescue
    e ->
      Logger.warning("[SessionTitler] put_title failed: #{Exception.message(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Pure core (testable)
  # ---------------------------------------------------------------------------

  @doc "Build the `{system, user}` prompt pair from a user message (input-capped)."
  @spec build_prompt(String.t()) :: {String.t(), String.t()}
  def build_prompt(user_text) do
    capped =
      user_text
      |> String.trim()
      |> truncate(@max_input_chars)

    {@system_prompt, capped}
  end

  @doc """
  Sanitize a raw model title into a single clean line.

  Takes the first non-empty line, strips a leading `Title:` label, removes
  surrounding quotes/backticks, collapses whitespace, drops trailing
  punctuation, and truncates to #{@max_title_chars} chars on a word boundary.
  Returns `""` if nothing usable remains.
  """
  @spec sanitize_title(String.t()) :: String.t()
  def sanitize_title(raw) when is_binary(raw) do
    raw
    |> first_nonempty_line()
    |> String.trim()
    |> strip_label()
    |> strip_wrapping_quotes()
    |> collapse_whitespace()
    |> strip_trailing_punctuation()
    |> truncate_words(@max_title_chars)
    |> String.trim()
  end

  def sanitize_title(_), do: ""

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A session counts as titled if EITHER store has one, so the automatic path
  # never fires over a manual `/rename`.
  defp has_title?(session_id) do
    case display_title(session_id) do
      t when is_binary(t) and t != "" -> true
      _ -> false
    end
  end

  # Manual title set via `/rename`, stored in the session's persisted metadata.
  # Kept separate from the automatic store so the two can be ordered by
  # precedence rather than racing to overwrite one file.
  defp manual_title(session_id) do
    case OptimalSystemAgent.Agent.SessionPersistence.get_metadata(session_id) do
      %{title: t} when is_binary(t) ->
        case String.trim(t) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Stage 2. Fire-and-forget on the general-purpose task supervisor with
  # `restart: :temporary`, so a crash here is contained and never retried into a
  # loop. Every failure path returns :ok — the stage-1 heuristic title stands.
  defp refine_async(session_id, opts) do
    chat_opts = Keyword.take(opts, [:chat_fun])

    Task.Supervisor.start_child(
      OptimalSystemAgent.TaskSupervisor,
      fn ->
        case title_for(session_id, chat_opts) do
          {:ok, title} ->
            broadcast_title(session_id, title)

          {:error, reason} ->
            Logger.debug("[SessionTitler] refinement skipped for #{session_id}: #{inspect(reason)}")
            :ok
        end
      end,
      restart: :temporary
    )

    :ok
  rescue
    # No supervisor (unit tests, partial boot) — the seed title is already stored.
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Tell the TUI a title now exists, so the status bar updates without polling.
  # Bus.emit is itself async + supervised, so this cannot block the caller.
  defp broadcast_title(session_id, title) do
    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :session_title,
      session_id: session_id,
      title: title
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Prompts arrive as prose, bullets, quotes or headings. Strip the leading
  # markup so "- fix the login bug" titles as "Fix the login bug", not
  # "- fix the login bug".
  defp strip_leading_markers(line) do
    Regex.replace(~r/^\s*(?:[>#*\-+•]+\s*|\d+[\.\)]\s+)/u, line, "")
  end

  defp capitalize_first(""), do: ""

  defp capitalize_first(line) do
    {first, rest} = String.split_at(line, 1)
    String.upcase(first) <> rest
  end

  defp first_user_text(session_id) do
    session_id
    |> SessionTranscript.get_transcript()
    |> Enum.find(fn r -> r.role == "user" and is_binary(r.content) and String.trim(r.content) != "" end)
    |> case do
      nil -> {:error, :no_content}
      r -> {:ok, r.content}
    end
  rescue
    _ -> {:error, :no_content}
  end

  defp first_nonempty_line(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", fn l -> l != "" end)
  end

  defp strip_label(line), do: Regex.replace(~r/^\s*title\s*[:\-]\s*/i, line, "")

  defp strip_wrapping_quotes(line) do
    line
    |> String.trim()
    |> case do
      <<q::utf8, rest::binary>> = full when q in [?", ?', ?`] ->
        if String.ends_with?(rest, <<q::utf8>>) and byte_size(rest) >= 1 do
          String.slice(rest, 0, String.length(rest) - 1)
        else
          full
        end

      other ->
        other
    end
  end

  defp collapse_whitespace(line), do: line |> String.replace(~r/\s+/, " ") |> String.trim()

  defp strip_trailing_punctuation(line), do: String.replace(line, ~r/[\.,;:!]+$/, "")

  defp truncate_words(line, max) do
    if String.length(line) <= max do
      line
    else
      truncated = String.slice(line, 0, max)

      case String.split(truncated, " ") do
        parts when length(parts) > 1 ->
          parts |> Enum.drop(-1) |> Enum.join(" ")

        _ ->
          truncated
      end
    end
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: binary_part(s, 0, max)

  defp default_chat(system, user) do
    messages = [
      %{role: "system", content: system},
      %{role: "user", content: user}
    ]

    opts = [temperature: 0.3, max_tokens: 40] ++ small_model_opts()

    case Providers.chat(messages, opts) do
      {:ok, %{content: content}} when is_binary(content) and content != "" -> {:ok, content}
      {:ok, other} -> {:error, {:empty_response, other}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    _, reason -> {:error, reason}
  end

  @doc """
  Provider/model options for the titling call, resolved from the LIVE catalog.

  A one-line title is the cheapest possible request, so it should not run on the
  session's main model. The model is resolved at call time via
  `Catalog.small_model/1`, which ranks the *current* catalog (models.dev data,
  cached and refreshed in the background) by cost and recency and prefers
  small-class names. Nothing here names a model.

  Hardcoding was the alternative and it is the thing that keeps breaking: static
  id lists rot silently as providers retire and rename models, and the failure is
  invisible until a call 404s. Reading the catalog means the pick tracks whatever
  the provider actually offers today.

  Returns `[]` — meaning "just use the session's normal model" — whenever the
  catalog cannot name one (offline with no snapshot, unknown provider, or a
  provider whose small model the Registry does not recognize).
  """
  @spec small_model_opts() :: keyword()
  def small_model_opts do
    provider = OptimalSystemAgent.Runtime.Identity.provider()

    case Catalog.small_model(to_string(provider)) do
      %{model_id: model_id} when is_binary(model_id) and model_id != "" ->
        if Providers.known_model?(provider, model_id) do
          [provider: provider, model: model_id]
        else
          []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Resolved through ConfigFile so the automatic-title store always lands in the
  # same config dir as the manual-title store (`SessionPersistence`). They are
  # read together by `display_title/2`, so they must not be able to disagree
  # about where "the config dir" is (bootstrap_dir fallback, `~` expansion).
  defp titles_file do
    Path.join(OptimalSystemAgent.ConfigFile.config_dir(), "session_titles.json")
  end
end
