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

  ## Follow-up (out of scope here — touches areas I do not own)
    * Persist the title on the `session_transcripts` table (needs a migration).
    * Surface the title in the TUI session list / tab bar.
    * Regenerate the title once a session accrues enough turns.
  """

  require Logger

  alias OptimalSystemAgent.Store.SessionTranscript
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

    case Providers.chat(messages, temperature: 0.3, max_tokens: 40) do
      {:ok, %{content: content}} when is_binary(content) and content != "" -> {:ok, content}
      {:ok, other} -> {:error, {:empty_response, other}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp titles_file do
    dir = Application.get_env(:optimal_system_agent, :config_dir, Path.expand("~/.osa"))
    Path.join(dir, "session_titles.json")
  end
end
