defmodule OptimalSystemAgent.Agent.Trajectory do
  @moduledoc """
  Per-turn trajectory recording for debugging, replay, and training.

  Each LLM round-trip is captured as a JSONL entry appended to
  `~/.osa/trajectories/{session_id}.jsonl`. Entries include:

    * timestamp
    * session_id
    * model
    * input_tokens / output_tokens / cache stats
    * cost_usd (this round-trip)
    * tool_calls (names + arguments, truncated)
    * tool_results (truncated)
    * assistant_response (truncated)
    * context_utilization (at time of call)
    * compaction_events (if any fired this round-trip)

  ## Configuration

      # config/config.exs
      config :optimal_system_agent, :trajectory_recording, true

      # ~/.osa/config.toml
      [trajectory]
      enabled = true
      max_field_chars = 2000
      retention_days = 30

  Disabled by default. Enable via config to start recording.

  ## Secret redaction

  Tool-call arguments, tool results, assistant responses and compaction
  events are the places where API keys, `.env` contents and `Authorization`
  headers actually show up. Every such field is passed through `redact/1`
  before it is written, so known secret shapes (provider `sk-`/`sk_`/`xai-`
  keys, GitHub/GitLab/Slack tokens, AWS key ids, Google keys, JWTs, PEM
  private-key blocks, URL userinfo and OAuth query parameters, `Bearer`/
  `Basic` headers and `KEY=value` pairs whose key looks like a credential) are
  replaced with a `[REDACTED]` marker. The operator's home directory is
  rewritten to `~`. `redact/1` fails CLOSED: if the scrubber raises, the field
  is dropped, never passed through.

  Text OSA types into a computer (`computer_use`/`browser` `type`, `fill`,
  `clipboard_set`) has no secret shape at all — it is a password whenever the
  model fills a login form — so it is masked structurally by argument name via
  `Security.TypedText` and stored as `"<12 chars>"`.

  Redaction of free text is still pattern-based, not a guarantee: a trajectory
  file is a transcript of the session. It is created `0600` before the first
  write, under a `0700` directory. Treat `~/.osa/trajectories/` as sensitive.

  ## Retention

  `maybe_prune/0` is called at boot when recording is enabled and deletes
  trajectory files older than `retention_days` (default 30).

  ## Usage

  The recording hook is called from `Loop.Accounting.record/2` — operators
  don't call it directly. To read trajectories:

      Trajectory.read(session_id)       # → [entry, ...]
      Trajectory.list_sessions()        # → [session_id, ...]
      Trajectory.session_path(session_id)  # → path string
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Security.TypedText
  alias OptimalSystemAgent.Utils.Text

  @trajectory_dir "trajectories"
  @default_max_field_chars 2_000
  @default_retention_days 30

  # What `redact/1` returns when the scrubber itself raises. Fail closed: the
  # caller gets a marker, never the unscrubbed input.
  @redaction_failure_marker "[REDACTED — secret scrubber failed]"

  # Trajectories hold credentials by design. Owner-only, set before the first
  # byte is written.
  @trajectory_file_mode 0o600

  # Ordered highest-signal-first. Each entry is `{pattern, replacement}` and is
  # applied to every free-text field before it is written to disk.
  @secret_patterns [
    # A PEM block is multiline, so no single-line pattern below can see it. It
    # has to come first: `cat id_rsa` in a tool result is a full private key.
    {~r/(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----/,
     "[REDACTED_PRIVATE_KEY]"},
    # `scheme://user:pass@host` — the password is in the URL itself, and URLs
    # are quoted whole into tool arguments and results.
    {~r{([a-zA-Z][a-zA-Z0-9+.\-]*://)([^/\s:@]+):([^/\s@]+)@}, "\\1\\2:[REDACTED]@"},
    # OAuth/OIDC query parameters. These are bearer-equivalent for the life of
    # the token and land in trajectories via redirect URLs the agent follows.
    {~r/\b(access_token|refresh_token|id_token|client_secret|code|state)(=)([^&\s"']{4,})/i,
     "\\1\\2[REDACTED]"},
    # `sk_` as well as `sk-` (Stripe-style), and `xai-` because OSA ships an
    # xAI provider — that key shape is one OSA's own users will have.
    {~r/\bsk[-_][A-Za-z0-9_\-]{16,}/, "sk-[REDACTED]"},
    {~r/\bxai-[A-Za-z0-9_\-]{16,}/, "[REDACTED_XAI_KEY]"},
    {~r/\bglpat-[A-Za-z0-9_\-]{16,}/, "[REDACTED_GITLAB_TOKEN]"},
    {~r/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/, "[REDACTED_GITHUB_TOKEN]"},
    {~r/\bgithub_pat_[A-Za-z0-9_]{20,}/, "[REDACTED_GITHUB_TOKEN]"},
    {~r/\bxox[abprs]-[A-Za-z0-9\-]{10,}/, "[REDACTED_SLACK_TOKEN]"},
    {~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, "[REDACTED_AWS_KEY_ID]"},
    {~r/\bAIza[0-9A-Za-z_\-]{35}\b/, "[REDACTED_GOOGLE_KEY]"},
    {~r/\bey[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}/, "[REDACTED_JWT]"},
    {~r/\b(Bearer|Basic)\s+[A-Za-z0-9_\-\.=\+\/]{12,}/i, "\\1 [REDACTED]"},
    # `KEY=value`, `"key": "value"`, `key = value` where the key name looks
    # like a credential. Covers .env dumps and JSON tool arguments alike.
    #
    # The `(?!\d+(?:\.\d+)?\b)` on the VALUE keeps this usable on reasoning
    # text, which is now redacted too. `token` is a substring of `max_tokens`,
    # `token_count`, `output_tokens` — all of which the model discusses with a
    # number attached, and all of which came back as `max_tokens = [REDACTED]`.
    # A purely numeric value is not a credential in any shape this list
    # targets, so excluding it costs no coverage: a numeric-looking key with a
    # trailing non-digit (`sk-1234...abcd`, a hex secret) fails the lookahead's
    # `\b` and is still redacted.
    {~r/("?[A-Za-z0-9_\-]*(?:api[_\-]?key|secret|token|password|passwd|credential|private[_\-]?key)[A-Za-z0-9_\-]*"?)(\s*[:=]\s*)("?)(?!\d+(?:\.\d+)?\b)([^"\s,}\n]{4,})/i,
     "\\1\\2\\3[REDACTED]"}
  ]

  @type entry :: %{
          timestamp: String.t(),
          session_id: String.t(),
          model: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          requested_at: DateTime.t() | nil,
          cost_usd: float(),
          tool_calls: [map()],
          tool_results: [String.t()],
          assistant_response: String.t(),
          context_utilization: float(),
          compaction_events: [map()]
        }

  @doc "Is trajectory recording enabled?"
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :trajectory_recording, false) or
      toml_enabled?()
  end

  defp toml_enabled? do
    try do
      case ConfigFile.get(["trajectory", "enabled"]) do
        v when is_boolean(v) -> v
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  @doc "Max chars to store per field (tool args, results, responses)."
  @spec max_field_chars() :: pos_integer()
  def max_field_chars do
    Application.get_env(:optimal_system_agent, :trajectory_max_field_chars) ||
      toml_max_chars() ||
      @default_max_field_chars
  end

  defp toml_max_chars do
    try do
      case ConfigFile.get(["trajectory", "max_field_chars"]) do
        n when is_integer(n) and n > 0 -> n
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc "Directory where trajectory files are stored."
  @spec dir() :: String.t()
  def dir do
    Path.join(ConfigFile.config_dir(), @trajectory_dir)
  end

  @doc "Full path for a session's trajectory file."
  @spec session_path(String.t()) :: String.t()
  def session_path(session_id) do
    safe_id = sanitize_session_id(session_id)
    Path.join(dir(), "#{safe_id}.jsonl")
  end

  @doc """
  Record a single LLM round-trip as a JSONL entry.

  Called from `Loop.Accounting.record/2` after each provider response.
  Best-effort — a write failure is logged and swallowed, never propagated.
  """
  @spec record(map()) :: :ok | {:error, term()}
  def record(%{session_id: session_id} = entry) when is_binary(session_id) do
    # `unless enabled?(), do: :ok` does NOT return early — Elixir has no early
    # return, so the expression was evaluated, discarded, and the write ran
    # unconditionally. Trajectory recording is documented as opt-in and writes
    # raw conversation content to disk, so the guard has to actually branch.
    if enabled?() do
      do_record(session_id, entry)
    else
      :ok
    end
  end

  def record(_), do: :ok

  defp do_record(session_id, entry) do
    path = session_path(session_id)

    try do
      dir = Path.dirname(path)
      File.mkdir_p(dir)
      File.chmod(dir, 0o700)

      line = encode_entry(entry)

      # chmod BEFORE the first write, not after: a file created under the
      # process umask is world-readable for the window between creation and a
      # trailing chmod, and this file is a transcript that holds credentials.
      ensure_owner_only(path)

      :ok = File.write(path, line <> "\n", [:append, :utf8])
      :ok
    rescue
      e ->
        Logger.warning("Trajectory.record failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    catch
      kind, reason ->
        Logger.warning("Trajectory.record caught #{kind}: #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  @doc "Read all trajectory entries for a session."
  @spec read(String.t()) :: [map()]
  def read(session_id) do
    path = session_path(session_id)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode/1)
        |> Enum.filter(fn
          {:ok, _} -> true
          _ -> false
        end)
        |> Enum.map(&elem(&1, 1))

      {:error, _} ->
        []
    end
  end

  @doc """
  Turn one stored row back into a usage map `Agent.Pricing` can price.

  This is the other half of persisting `requested_at`. The row spells the cache
  counters `cache_creation_tokens` / `cache_read_tokens`; `Pricing` wants
  `cache_creation_input_tokens` / `cache_read_input_tokens`. A caller re-costing
  a stored session had to know that, and a caller that got it wrong would silently
  bill the cached prompt at zero — so the mapping lives here, once, next to the
  writer it has to agree with.

  The returned map carries `:requested_at` when the row has one, which is what
  makes `Pricing.cost/2` on the result return the SAME dollar figure the row
  already records, at any hour, forever. A row written before this field existed
  has none; it re-prices against the wall clock, exactly as it always did, and
  the absence is visible rather than papered over with the row's `timestamp`
  (which is when the response landed, not when the request went out).
  """
  @spec usage_of(map()) :: map()
  def usage_of(row) when is_map(row) do
    base = %{
      input_tokens: row_int(row, "input_tokens"),
      output_tokens: row_int(row, "output_tokens"),
      cache_creation_input_tokens: row_int(row, "cache_creation_tokens"),
      cache_read_input_tokens: row_int(row, "cache_read_tokens")
    }

    case decode_instant(Map.get(row, "requested_at") || Map.get(row, :requested_at)) do
      nil -> base
      at -> Map.put(base, :requested_at, at)
    end
  end

  defp row_int(row, key) do
    case Map.get(row, key) || Map.get(row, String.to_atom(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp encode_instant(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_instant(_), do: nil

  defp decode_instant(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp decode_instant(%DateTime{} = dt), do: dt
  defp decode_instant(_), do: nil

  @doc "List all session IDs that have trajectory files."
  @spec list_sessions() :: [String.t()]
  def list_sessions do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&String.replace_trailing(&1, ".jsonl", ""))

      {:error, _} ->
        []
    end
  end

  @doc """
  Days to keep trajectory files before `maybe_prune/0` deletes them.
  """
  @spec retention_days() :: pos_integer()
  def retention_days do
    Application.get_env(:optimal_system_agent, :trajectory_retention_days) ||
      toml_retention_days() ||
      @default_retention_days
  end

  defp toml_retention_days do
    case ConfigFile.get(["trajectory", "retention_days"]) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Prune expired trajectory files. Called at boot from `Application.start/2`.

  A no-op when recording is disabled — nothing new is being written, and
  deleting a disabled operator's archive is not this function's call. Returns
  the number of files removed.
  """
  @spec maybe_prune() :: non_neg_integer()
  def maybe_prune do
    if enabled?() do
      days = retention_days()
      removed = prune(days)

      if removed > 0 do
        Logger.info("Trajectory: pruned #{removed} trajectory file(s) older than #{days}d")
      end

      removed
    else
      0
    end
  rescue
    e ->
      Logger.warning("Trajectory.maybe_prune failed: #{Exception.message(e)}")
      0
  end

  @doc "Delete trajectory files older than `max_age_days`."
  @spec prune(pos_integer()) :: non_neg_integer()
  def prune(max_age_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_days, :day)

    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.count(fn file ->
          path = Path.join(dir(), file)

          case File.stat(path) do
            {:ok, %{mtime: mtime}} ->
              mtime_dt = DateTime.from_naive!(NaiveDateTime.from_erl!(mtime), "Etc/UTC")

              if DateTime.compare(mtime_dt, cutoff) == :lt do
                File.rm(path)
                true
              else
                false
              end

            _ ->
              false
          end
        end)

      {:error, _} ->
        0
    end
  end

  # --- Private ---

  # Create the file 0600 if it does not exist yet, and repair the mode if an
  # earlier build created it under the umask.
  defp ensure_owner_only(path) do
    unless File.exists?(path) do
      File.write(path, "", [:write])
    end

    File.chmod(path, @trajectory_file_mode)
    :ok
  end

  defp encode_entry(entry) do
    %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "session_id" => Map.get(entry, :session_id, ""),
      "model" => Map.get(entry, :model, ""),
      "input_tokens" => Map.get(entry, :input_tokens, 0),
      "output_tokens" => Map.get(entry, :output_tokens, 0),
      "cache_creation_tokens" => Map.get(entry, :cache_creation_tokens, 0),
      "cache_read_tokens" => Map.get(entry, :cache_read_tokens, 0),
      # `timestamp` above is when this row was WRITTEN, which is after the
      # response landed. `requested_at` is when the request was ISSUED, and it
      # is the only one of the two that can reproduce `cost_usd` — rates move
      # by date and by hour of day, and a turn that streamed across a boundary
      # was written on the far side of the tier it was billed at. Null on a row
      # whose caller did not stamp one; `usage_of/1` then declines to invent it.
      "requested_at" => encode_instant(Map.get(entry, :requested_at)),
      "cost_usd" => Map.get(entry, :cost_usd, 0.0),
      "tool_calls" => truncate_tool_calls(Map.get(entry, :tool_calls, [])),
      "tool_results" => truncate_list(Map.get(entry, :tool_results, [])),
      "assistant_response" => truncate(Map.get(entry, :assistant_response, "")),
      "context_utilization" => Map.get(entry, :context_utilization, 0.0),
      # Compaction events used to be written raw — they are summaries of the
      # conversation being compacted, so they carry the same content every
      # other field is scrubbed for. Route them through the same pipeline.
      "compaction_events" => sanitize_term(Map.get(entry, :compaction_events, []))
    }
    |> Jason.encode!()
  end

  # Recursively redact every string inside an arbitrary JSON-able term.
  defp sanitize_term(term) when is_binary(term), do: truncate(term)

  defp sanitize_term(term) when is_list(term), do: Enum.map(term, &sanitize_term/1)

  defp sanitize_term(%{__struct__: _} = term), do: sanitize_term(inspect(term))

  defp sanitize_term(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {sanitize_key(k), sanitize_term(v)} end)
  end

  defp sanitize_term(term) when is_atom(term) or is_number(term), do: term
  defp sanitize_term(term), do: truncate(inspect(term))

  defp sanitize_key(k) when is_binary(k) or is_atom(k) or is_number(k), do: k
  defp sanitize_key(k), do: inspect(k)

  defp truncate(nil), do: ""

  defp truncate(s) when is_binary(s) do
    # Redact BEFORE truncating: truncation must never be the thing that decides
    # whether a key made it to disk, and a half-truncated key is still a leak.
    s = redact(s)
    max = max_field_chars()

    if byte_size(s) > max do
      # A raw byte cut can land mid-codepoint and produce invalid UTF-8;
      # `Jason.encode!/1` then raises and `do_record/2`'s rescue discards the
      # WHOLE trajectory entry. `utf8_head/2` cuts back to a character
      # boundary.
      #
      # NOTE: `max_field_chars` is compared against `byte_size/1`, so despite
      # the name this budget is enforced in BYTES. That is the safe direction
      # (a byte cap can never under-count the on-disk cost of a field) and is
      # left as-is deliberately — the name is a config key that operators
      # already set.
      Text.utf8_head(s, max) <> "…[truncated]"
    else
      s
    end
  end

  defp truncate(v), do: truncate(to_string(v))

  @doc """
  Replace known secret shapes in `text` with `[REDACTED]` markers.

  Applied to every tool-call argument, tool result and assistant response
  before it is written. Pattern-based and therefore best-effort — it catches
  the shapes that actually leak (provider keys, GitHub/Slack tokens, AWS key
  ids, Google keys, JWTs, `Authorization` headers, and `KEY=value` pairs whose
  key name reads like a credential) but cannot catch an opaque secret with no
  distinguishing shape.
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text), do: redact(text, @secret_patterns)

  def redact(other), do: other

  @doc false
  # `patterns` is injectable so the failure path can be exercised in tests.
  @spec redact(String.t(), [{Regex.t(), term()}]) :: String.t()
  def redact(text, patterns) when is_binary(text) and is_list(patterns) do
    # `Regex.replace/3` does not raise on invalid UTF-8 — it silently matches
    # nothing and hands the input back. That is a fail-open: a key sitting in a
    # tool result that also contains one stray byte was written to disk
    # completely unredacted. Coerce to valid UTF-8 first so the patterns can
    # actually see the text.
    text
    |> coerce_utf8()
    |> then(fn t ->
      Enum.reduce(patterns, t, fn {pattern, replacement}, acc ->
        Regex.replace(pattern, acc, replacement)
      end)
    end)
    |> anonymize_home()
  rescue
    e ->
      # A sanitizer that returns its input when it fails is not a sanitizer:
      # the original callers wrote the UNREDACTED text to
      # `~/.osa/trajectories/` and printed it to the terminal on any regex
      # error. Fail closed — the content is dropped, never passed through.
      Logger.error("Trajectory.redact failed, dropping content: #{Exception.message(e)}")
      @redaction_failure_marker
  end

  @doc """
  Replace the operator's home directory with `~`.

  A trajectory is shared as a debug artifact; the real home path carries the
  operator's username. Only the directory form is rewritten — replacing a bare
  username everywhere would mangle unrelated text.
  """
  @spec anonymize_home(String.t()) :: String.t()
  def anonymize_home(text) when is_binary(text) do
    case home_dir() do
      nil -> text
      home -> String.replace(text, home, "~")
    end
  end

  # Replace invalid byte sequences with U+FFFD so the scrubber can run. Cheap
  # no-op for the overwhelmingly common valid case.
  defp coerce_utf8(text) do
    if String.valid?(text), do: text, else: do_coerce(text, [])
  end

  defp do_coerce(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_coerce(<<c::utf8, rest::binary>>, acc), do: do_coerce(rest, [<<c::utf8>> | acc])

  defp do_coerce(<<_bad, rest::binary>>, acc), do: do_coerce(rest, ["�" | acc])

  defp home_dir do
    case System.get_env("HOME") || System.get_env("USERPROFILE") do
      nil -> nil
      "" -> nil
      "/" -> nil
      home -> String.trim_trailing(home, "/")
    end
  end

  defp truncate_list(list) when is_list(list) do
    Enum.map(list, &truncate/1)
  end

  defp truncate_list(_), do: []

  defp truncate_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        "name" => Map.get(call, :name, Map.get(call, "name", "")),
        "arguments" =>
          call
          |> Map.get(:arguments, Map.get(call, "arguments", ""))
          |> mask_typed_text()
          |> truncate()
      }
    end)
  end

  defp truncate_tool_calls(_), do: []

  # A `computer_use`/`browser` typing action carries the literal keystrokes —
  # a password when the model is filling a login form. `redact/1` cannot help:
  # a password has no shape. Mask structurally, by argument name, before the
  # value reaches disk.
  defp mask_typed_text(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        case Jason.encode(TypedText.mask_args(decoded)) do
          {:ok, json} -> json
          _ -> args
        end

      _ ->
        args
    end
  end

  defp mask_typed_text(args) when is_map(args) or is_list(args) do
    masked = TypedText.mask_args(args)

    case Jason.encode(masked) do
      {:ok, json} -> json
      _ -> inspect(masked)
    end
  end

  defp mask_typed_text(other), do: other

  defp sanitize_session_id(id) when is_binary(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "_")
    |> String.slice(0, 100)
  end

  defp sanitize_session_id(_), do: "unknown"
end
