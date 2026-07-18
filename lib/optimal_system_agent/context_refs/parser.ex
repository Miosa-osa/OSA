defmodule OptimalSystemAgent.ContextRefs.Parser do
  @moduledoc "Extracts @ref tokens from user message text."

  @type ref ::
          {:file, String.t(), {non_neg_integer() | nil, non_neg_integer() | nil}}
          | {:diff, nil}
          | {:staged, nil}
          | {:git, pos_integer()}
          | {:url, String.t()}

  @ref_pattern ~r/
    @file:([^\s]+)          |  # @file:path\/to\/file.ex or @file:path:10-25
    @diff\b                 |  # @diff
    @staged\b               |  # @staged
    @git:(\d+)              |  # @git:5
    @url:(https?:\/\/[^\s]+)   # @url:https:\/\/example.com
  /x

  # Bare @-mention forms (Claude Code src/utils/attachments.ts
  # extractAtMentionedFiles pattern):
  #   @"path with spaces.txt"   quoted — exact path, may contain spaces
  #   @lib/foo.ex               unquoted — no spaces
  # A bare token only becomes a file ref when the path exists on disk, so
  # ordinary prose like "ping @here" or "@channel" is never treated as a file.
  @quoted_mention ~r/(?:^|\s)@"([^"]+)"/
  @unquoted_mention ~r/(?:^|\s)@([^\s]+)/

  # Prose punctuation an unquoted [^\s]+ token may have swallowed
  # ("see @lib/foo.ex." / "check @foo,"). Deliberately excludes "/" so
  # directory mentions with a trailing slash survive.
  @trailing_punct ~r/[.,;:!?)\]}'"`]+$/

  @doc """
  Extract @refs from a user message.

  Typed refs (`@file:`, `@diff`, `@staged`, `@git:N`, `@url:`) are stripped
  from the returned cleaned text. Bare `@path` mentions (what the TUI file
  picker inserts) are left in place in the prose and only produce a ref when
  the path exists — resolved against `opts[:working_dir]` when given, else
  the process cwd.
  """
  @spec parse(String.t(), keyword()) :: {cleaned :: String.t(), refs :: [ref()]}
  def parse(message, opts \\ []) when is_binary(message) do
    working_dir = Keyword.get(opts, :working_dir)

    typed_refs =
      Regex.scan(@ref_pattern, message)
      |> Enum.map(&match_to_ref/1)
      |> Enum.reject(&is_nil/1)

    cleaned =
      Regex.replace(@ref_pattern, message, "")
      |> String.trim()

    # Scan bare mentions on the cleaned text so typed forms are not re-matched.
    bare_refs = extract_bare_mentions(cleaned, working_dir)

    {cleaned, Enum.uniq(typed_refs ++ bare_refs)}
  end

  defp match_to_ref([full | _]) do
    cond do
      String.starts_with?(full, "@file:") ->
        raw = String.trim_leading(full, "@file:")
        parse_file_ref(raw)

      full == "@diff" ->
        {:diff, nil}

      full == "@staged" ->
        {:staged, nil}

      String.starts_with?(full, "@git:") ->
        n = full |> String.trim_leading("@git:") |> String.to_integer()
        {:git, max(n, 1)}

      String.starts_with?(full, "@url:") ->
        url = String.trim_leading(full, "@url:")
        {:url, url}

      true ->
        nil
    end
  end

  defp parse_file_ref(raw) do
    {path, range} = split_path_and_range(raw)
    {:file, path, range}
  end

  # Line-range syntaxes, both supported for typed and bare mentions:
  #   path:10-25 / path:10      (OSA typed form)
  #   path#L10-20 / path#L10    (Claude Code fragment form; #L10 means line 10 only)
  # Non-line `#fragment` suffixes (e.g. README.md#usage) are stripped, per
  # Claude Code parseAtMentionedFileLines. Reversed ranges are normalized so
  # Enum.slice never sees a decreasing range.
  defp split_path_and_range(raw) do
    cond do
      m = Regex.run(~r/^([^#]+)#L(\d+)-(\d+)(?:#.*)?$/, raw) ->
        [_, path, first, last] = m
        {a, b} = {String.to_integer(first), String.to_integer(last)}
        {path, {min(a, b), max(a, b)}}

      m = Regex.run(~r/^([^#]+)#L(\d+)(?:#.*)?$/, raw) ->
        [_, path, line] = m
        n = String.to_integer(line)
        {path, {n, n}}

      m = Regex.run(~r/^([^#]+)#.+$/, raw) ->
        [_, path] = m
        {path, {nil, nil}}

      m = Regex.run(~r/^(.+):(\d+)-(\d+)$/, raw) ->
        [_, path, first, last] = m
        {a, b} = {String.to_integer(first), String.to_integer(last)}
        {path, {min(a, b), max(a, b)}}

      m = Regex.run(~r/^(.+):(\d+)$/, raw) ->
        [_, path, line] = m
        {path, {String.to_integer(line), nil}}

      true ->
        {raw, {nil, nil}}
    end
  end

  # --- Bare @path mentions (Claude Code extractAtMentionedFiles model) ---

  defp extract_bare_mentions(text, working_dir) do
    quoted =
      Regex.scan(@quoted_mention, text)
      |> Enum.map(fn [_, path] -> path end)
      # Reserved for future @"name (agent)" autocomplete forms — never a file.
      |> Enum.reject(&String.ends_with?(&1, " (agent)"))
      |> Enum.map(&{&1, :quoted})

    unquoted =
      Regex.scan(@unquoted_mention, text)
      |> Enum.map(fn [_, token] -> token end)
      # Quoted forms are handled above; @agent-* is an agent mention, not a file.
      |> Enum.reject(fn token ->
        String.starts_with?(token, "\"") or String.starts_with?(token, "agent-")
      end)
      |> Enum.map(&{&1, :unquoted})

    (quoted ++ unquoted)
    |> Enum.map(fn {token, kind} -> bare_token_to_ref(token, kind, working_dir) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Quoted tokens are exact paths — no punctuation stripping.
  defp bare_token_to_ref(token, :quoted, working_dir) do
    resolve_bare_candidate(token, working_dir)
  end

  # Unquoted tokens may have swallowed trailing prose punctuation. Try the raw
  # token first (a path really can end in ")" or "."), then the stripped one.
  defp bare_token_to_ref(token, :unquoted, working_dir) do
    stripped = Regex.replace(@trailing_punct, token, "")

    [token, stripped]
    |> Enum.uniq()
    |> Enum.find_value(fn candidate ->
      if candidate != "", do: resolve_bare_candidate(candidate, working_dir)
    end)
  end

  # File.exists? gate — the Claude Code null-filter (attachments.ts
  # processAtMentionedFiles): bare tokens that don't stat as a real path are
  # plain prose and produce no ref. A literal on-disk match (e.g. a file
  # actually named "foo.ex:10" or containing "#") wins over range parsing.
  defp resolve_bare_candidate(token, working_dir) do
    cond do
      token != "" and File.exists?(expand(token, working_dir)) ->
        {:file, token, {nil, nil}}

      true ->
        {path, range} = split_path_and_range(token)

        if path != "" and path != token and File.exists?(expand(path, working_dir)) do
          {:file, path, range}
        end
    end
  end

  defp expand(path, nil), do: Path.expand(path)
  defp expand(path, working_dir), do: Path.expand(path, working_dir)
end
