defmodule OptimalSystemAgent.Skills.Validator do
  @moduledoc """
  Authoring validation for `SKILL.md` files — the gate the *loader* never had.

  `Skills.Capture` gates the LEARNED library (skills the agent writes to itself
  at runtime). This module gates the other half: the author-curated `SKILL.md`
  files discovered by `Tools.Registry.SkillLoader`.

  ## Why this exists

  The loader is deliberately forgiving: when frontmatter is absent, unterminated
  within the bounded read window, or invalid YAML, it falls back to naming the
  skill after its parent directory and using the first 100 raw bytes of the file
  as the description. That fallback keeps a bad file from crashing discovery —
  but on its own it is silent, and silence is the failure mode:

    * a typo'd `descrption:` key gives the skill an empty description, which is
      the highest-weight `when_to_use` field the ranker has. The skill is loaded,
      surfaced with no trigger text, and effectively never matches a task.
    * a missing/absent `name:` names the skill after its directory, so
      cross-scope precedence (`local` > `repo` > `user` > `bundled`) silently
      shadows or fails to shadow the wrong file.
    * `---` frontmatter that closes past byte #{4096} parses as no frontmatter at
      all, so a large header block degrades the skill to a raw-bytes description.

  In every one of those cases the author gets no feedback: the skill *appears* to
  load. This module produces that feedback, and `Skills.Lint` + `mix
  osa.skills.lint` make it runnable (and CI-enforceable) by the author.

  ## Contract

  `validate_file/1` returns a list of `t:finding/0` maps — `[]` means clean.
  Every finding names **what is wrong AND how to fix it**; that is a hard rule
  of this module, pinned by `Skills.ValidatorTest`.

  Severity:

    * `:error`   — the skill will load WRONG (misnamed, untriggered, bodyless).
                   `mix osa.skills.lint` exits non-zero.
    * `:warning` — the skill loads correctly but is degraded or non-portable
                   (thin description, unknown frontmatter key, oversized body).

  This module performs the file read only; it never mutates anything.
  """

  # Must stay in sync with SkillLoader's bounded frontmatter window: frontmatter
  # that closes past this point is invisible to the loader.
  @frontmatter_max_bytes 4_096

  # Claude/agent-compatible skill name: lowercase, digits, hyphens.
  @name_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @max_name_len 64

  # A description IS the ranker's primary trigger text. Too short and the skill
  # cannot be matched to a task; too long and it floods the listing surface.
  @min_description_len 20
  @max_description_len 1_024

  # A body under this is not a procedure, it's a stub.
  @min_body_len 40

  # Soft cap: bodies are loaded whole on invoke, so a huge one is a context bomb.
  @max_body_bytes 64 * 1_024

  # Keys the loader actually reads (see SkillLoader.build_entry/3 and
  # normalize_triggers/1). Anything else is inert — usually a typo.
  @known_keys ~w(
    name skill_name skill description
    trigger triggers trigger_keywords
    priority tools paths
    version author license allowed-tools allowed_tools model metadata category
  )

  @priority_words ~w(critical high medium low)

  @type severity :: :error | :warning

  @type finding :: %{
          severity: severity(),
          rule: atom(),
          path: String.t(),
          message: String.t()
        }

  @doc """
  Validate a `SKILL.md` file on disk. Returns `[]` when the file is clean.

  Reads the whole file (unlike discovery, which is bounded) because body checks
  need it. Intended for authoring/lint time, not for the hot discovery path —
  use `check_entry/1` there.
  """
  @spec validate_file(String.t()) :: [finding()]
  def validate_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        validate_content(content, path)

      {:error, reason} ->
        [
          finding(
            :error,
            :unreadable,
            path,
            "SKILL.md could not be read (#{:file.format_error(reason)}). " <>
              "Fix: check the file exists and is readable by the agent process."
          )
        ]
    end
  end

  def validate_file(other) do
    [finding(:error, :bad_path, inspect(other), "Fix: pass an absolute path to a SKILL.md file.")]
  end

  @doc """
  Validate raw `SKILL.md` content. `path` is used for reporting only.

  Split out from `validate_file/1` so callers that already hold the content
  (and tests) do not re-read the file.
  """
  @spec validate_content(String.t(), String.t()) :: [finding()]
  def validate_content(content, path) when is_binary(content) and is_binary(path) do
    case split_frontmatter(content) do
      {:ok, raw_frontmatter, body} ->
        structural_frontmatter_findings(raw_frontmatter, path) ++
          parse_and_validate(raw_frontmatter, body, path)

      {:error, rule, message} ->
        [finding(:error, rule, path, message)]
    end
  end

  @doc """
  Validate an already-loaded `SkillLoader` entry.

  The cheap half, intended for the discovery path: it catches exactly the
  failures that make a skill load WRONG — the silent fallback (no/unterminated
  frontmatter), an empty description, a bad name shape — and it never loads the
  instruction body. Detecting the fallback needs the frontmatter bytes rather
  than the entry alone (a fallback entry is indistinguishable from a valid one:
  it has a plausible name and a plausible description), so this re-reads the
  same bounded #{4096}-byte window discovery already read.

  Wiring this into `SkillLoader.read_frontmatter_entry/2` is what turns a silent
  fallback into an author-visible warning — see the module doc.
  """
  @spec check_entry(map()) :: [finding()]
  def check_entry(%{path: path} = entry) when is_binary(path) do
    name = Map.get(entry, :name) || ""
    description = Map.get(entry, :description) || ""

    fallback_findings(path) ++
      name_findings(name, path) ++ description_findings(description, path)
  end

  def check_entry(_), do: []

  # The loader's fallback path produces an entry that LOOKS fine. The only way
  # to tell is to look at the bytes it parsed (or failed to parse).
  defp fallback_findings(path) do
    case bounded_read(path, @frontmatter_max_bytes) do
      "" ->
        []

      data ->
        truncated? = byte_size(data) >= @frontmatter_max_bytes

        case {split_frontmatter(data), truncated?} do
          {{:ok, _fm, _body}, _} ->
            []

          # The window ran out mid-header: from discovery's point of view there
          # is no frontmatter at all, but "add a closing ---" would be wrong
          # advice — the closing fence is there, just out of reach.
          {{:error, :frontmatter_unterminated, _}, true} ->
            structural_frontmatter_findings(data, path)

          {{:error, rule, message}, _} ->
            [finding(:error, rule, path, message)]
        end
    end
  end

  defp bounded_read(path, n) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        data =
          case IO.binread(io, n) do
            bin when is_binary(bin) -> bin
            _ -> ""
          end

        File.close(io)
        data

      {:error, _} ->
        ""
    end
  rescue
    _ -> ""
  end

  @doc "True when `findings` contains at least one `:error`."
  @spec errors?([finding()]) :: boolean()
  def errors?(findings) when is_list(findings),
    do: Enum.any?(findings, &(&1.severity == :error))

  @doc """
  Render findings as an author-facing report block (one line per finding).

  Format: `  <SEVERITY>  <rule>  <path>\\n      <message>`
  """
  @spec format(([finding()])) :: String.t()
  def format([]), do: ""

  def format(findings) when is_list(findings) do
    findings
    |> Enum.sort_by(&{&1.path, severity_rank(&1.severity), &1.rule})
    |> Enum.map_join("\n", fn f ->
      "  #{String.pad_trailing(sev_label(f.severity), 7)} #{f.rule}\n" <>
        "      #{f.path}\n" <>
        "      #{f.message}"
    end)
  end

  # ── Frontmatter splitting ────────────────────────────────────────────────

  # Mirrors SkillLoader.parse_frontmatter/1's `String.split("---", parts: 3)`
  # shape, but distinguishes the three ways it can fail so the author gets an
  # actionable message instead of a silent fallback.
  defp split_frontmatter(content) do
    cond do
      not String.starts_with?(String.trim_leading(content), "---") ->
        {:error, :frontmatter_missing,
         "SKILL.md has no YAML frontmatter, so the skill is named after its directory " <>
           "and its first 100 bytes become the description. " <>
           "Fix: start the file with a `---` line, then `name:` and `description:`, then a closing `---`."}

      true ->
        case String.split(content, "---", parts: 3) do
          ["", frontmatter, body] ->
            {:ok, frontmatter, body}

          _ ->
            {:error, :frontmatter_unterminated,
             "the YAML frontmatter opens with `---` but never closes. " <>
               "Fix: add a closing `---` line after the last frontmatter key, before the instruction body."}
        end
    end
  end

  # The loader reads only the first @frontmatter_max_bytes. Frontmatter that
  # closes past that boundary parses as NO frontmatter at all.
  defp structural_frontmatter_findings(raw_frontmatter, path) do
    # +6 for the two `---` delimiters and their newlines.
    header_bytes = byte_size(raw_frontmatter) + 6

    if header_bytes > @frontmatter_max_bytes do
      [
        finding(
          :error,
          :frontmatter_too_large,
          path,
          "the frontmatter block is #{header_bytes} bytes, past the #{@frontmatter_max_bytes}-byte " <>
            "window discovery reads — the loader will see NO frontmatter and fall back to the " <>
            "directory name plus the first 100 raw bytes as the description. " <>
            "Fix: move prose out of the frontmatter into the instruction body below the closing `---`."
        )
      ]
    else
      []
    end
  end

  defp parse_and_validate(raw_frontmatter, body, path) do
    case YamlElixir.read_from_string(raw_frontmatter) do
      {:ok, meta} when is_map(meta) ->
        meta_findings(meta, path) ++ body_findings(body, path)

      {:ok, other} ->
        [
          finding(
            :error,
            :frontmatter_not_a_mapping,
            path,
            "the frontmatter parsed as #{inspect_type(other)}, not a key/value mapping. " <>
              "Fix: write it as YAML keys, e.g. `name: my-skill` on its own line."
          )
        ]

      {:error, reason} ->
        [
          finding(
            :error,
            :frontmatter_invalid_yaml,
            path,
            "the frontmatter is not valid YAML (#{yaml_reason(reason)}). " <>
              "Fix: check indentation (2 spaces, never tabs) and quote any value containing `:` or `#`."
          )
        ]
    end
  rescue
    e ->
      [
        finding(
          :error,
          :frontmatter_invalid_yaml,
          path,
          "the frontmatter could not be parsed as YAML (#{Exception.message(e)}). " <>
            "Fix: check indentation (2 spaces, never tabs) and quote any value containing `:` or `#`."
        )
      ]
  end

  # ── Field rules ──────────────────────────────────────────────────────────

  defp meta_findings(meta, path) do
    name = first_present(meta, ~w(name skill_name skill))
    description = to_string(meta["description"] || "")

    declared_name_findings(name, meta, path) ++
      name_findings(name || Path.basename(Path.dirname(path)), path) ++
      description_findings(description, path) ++
      priority_findings(meta["priority"], path) ++
      list_shape_findings(meta, path) ++
      unknown_key_findings(meta, path)
  end

  defp declared_name_findings(nil, meta, path) do
    dir = Path.basename(Path.dirname(path))

    typo = near_miss(Map.keys(meta), "name")

    hint =
      if typo,
        do: " (found `#{typo}:` — did you mean `name:`?)",
        else: ""

    [
      finding(
        :error,
        :name_missing,
        path,
        "no `name:` key in the frontmatter#{hint}, so the skill is silently named after its " <>
          "directory (`#{dir}`) — which breaks cross-scope precedence if any other scope " <>
          "declares that name properly. " <>
          "Fix: add `name: #{dir}` as the first frontmatter key."
      )
    ]
  end

  defp declared_name_findings(_name, _meta, _path), do: []

  defp name_findings(name, path) do
    name = to_string(name) |> String.trim()
    dir = Path.basename(Path.dirname(path))

    cond do
      name == "" ->
        []

      String.length(name) > @max_name_len ->
        [
          finding(
            :error,
            :name_too_long,
            path,
            "the skill name is #{String.length(name)} characters, over the #{@max_name_len}-character limit. " <>
              "Fix: shorten `name:` to a short hyphenated slug."
          )
        ]

      not Regex.match?(@name_regex, name) ->
        [
          finding(
            :error,
            :name_format,
            path,
            "the skill name `#{name}` is not a valid slug — invocation and cross-scope " <>
              "precedence match on this string exactly. " <>
              "Fix: use lowercase letters, digits and single hyphens only, e.g. `#{slugify(name)}`."
          )
        ]

      name != dir ->
        [
          finding(
            :warning,
            :name_directory_mismatch,
            path,
            "the declared name `#{name}` does not match the containing directory `#{dir}`; " <>
              "a malformed-frontmatter fallback elsewhere would name a skill `#{dir}`, colliding " <>
              "with this one under a different identity. " <>
              "Fix: rename the directory to `#{name}/`, or set `name: #{dir}`."
          )
        ]

      true ->
        []
    end
  end

  defp description_findings(description, path) do
    description = to_string(description) |> String.trim()
    len = String.length(description)

    cond do
      description == "" ->
        [
          finding(
            :error,
            :description_missing,
            path,
            "the skill has an empty `description:`. The description is the highest-signal " <>
              "field the ranker matches a task against, so this skill will effectively never " <>
              "surface. " <>
              "Fix: add `description:` stating WHAT the skill does and WHEN to use it."
          )
        ]

      len > @max_description_len ->
        [
          finding(
            :error,
            :description_too_long,
            path,
            "the description is #{len} characters, over the #{@max_description_len}-character limit; " <>
              "descriptions are listed for every skill, so an oversized one crowds out the rest. " <>
              "Fix: keep `description:` to one or two sentences and move detail into the body."
          )
        ]

      len < @min_description_len ->
        [
          finding(
            :warning,
            :description_too_short,
            path,
            "the description is only #{len} characters — too thin for relevance ranking to " <>
              "match it against a real task. " <>
              "Fix: expand `description:` to at least #{@min_description_len} characters naming the " <>
              "trigger situation, not just the skill's own name."
          )
        ]

      true ->
        []
    end
  end

  defp priority_findings(nil, _path), do: []

  defp priority_findings(p, _path) when is_integer(p) and p >= 0 and p <= 9, do: []

  defp priority_findings(p, path) when is_integer(p) do
    [
      finding(
        :warning,
        :priority_out_of_range,
        path,
        "`priority: #{p}` is outside the 0..9 range the loader orders on. " <>
          "Fix: use 0 (critical) through 9 (lowest); the default is 5."
      )
    ]
  end

  defp priority_findings(p, path) when is_binary(p) do
    trimmed = String.downcase(String.trim(p))

    valid? =
      trimmed in @priority_words or
        match?({n, ""} when n >= 0 and n <= 9, Integer.parse(trimmed))

    if valid? do
      []
    else
      [
        finding(
          :warning,
          :priority_invalid,
          path,
          "`priority: #{p}` is not recognised and silently becomes 5. " <>
            "Fix: use an integer 0..9 or one of #{Enum.join(@priority_words, ", ")}."
        )
      ]
    end
  end

  defp priority_findings(p, path) do
    [
      finding(
        :warning,
        :priority_invalid,
        path,
        "`priority:` is #{inspect_type(p)} and silently becomes 5. " <>
          "Fix: use an integer 0..9 or one of #{Enum.join(@priority_words, ", ")}."
      )
    ]
  end

  # `tools`, `triggers` and `paths` are each normalized from a YAML list OR a
  # comma-separated string. Any other shape is normalized to [] / nil — silently.
  defp list_shape_findings(meta, path) do
    Enum.flat_map(
      [
        {"tools", "the tool allowlist is dropped and the skill runs unrestricted"},
        {"triggers", "the skill loses its trigger keywords"},
        {"paths", "the skill is no longer path-gated and surfaces unconditionally"}
      ],
      fn {key, consequence} ->
        case Map.get(meta, key) do
          nil -> []
          v when is_list(v) -> non_scalar_items(v, key, consequence, path)
          v when is_binary(v) -> []
          v -> [bad_shape(key, v, consequence, path)]
        end
      end
    )
  end

  defp non_scalar_items(list, key, consequence, path) do
    if Enum.all?(list, &(is_binary(&1) or is_number(&1) or is_atom(&1))) do
      []
    else
      [bad_shape(key, list, consequence, path)]
    end
  end

  defp bad_shape(key, value, consequence, path) do
    finding(
      :warning,
      :"#{key}_bad_shape",
      path,
      "`#{key}:` is #{inspect_type(value)}; the loader accepts only a YAML list of strings " <>
        "or a comma-separated string, so #{consequence}. " <>
        "Fix: write `#{key}:` as a list of plain strings (one `- item` per line)."
    )
  end

  defp unknown_key_findings(meta, path) do
    meta
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 in @known_keys))
    |> Enum.sort()
    |> Enum.map(fn key ->
      suggestion =
        case near_miss(@known_keys, key) do
          nil -> "Fix: remove it, or move the value into the instruction body."
          hit -> "Fix: did you mean `#{hit}:`?"
        end

      finding(
        :warning,
        :unknown_frontmatter_key,
        path,
        "`#{key}:` is not a key the loader reads, so its value is inert. " <> suggestion
      )
    end)
  end

  defp body_findings(body, path) do
    trimmed = String.trim(body)
    bytes = byte_size(trimmed)

    cond do
      trimmed == "" ->
        [
          finding(
            :error,
            :body_missing,
            path,
            "the skill has frontmatter but no instruction body, so invoking it injects nothing. " <>
              "Fix: write the procedure below the closing `---`."
          )
        ]

      String.length(trimmed) < @min_body_len ->
        [
          finding(
            :warning,
            :body_too_thin,
            path,
            "the instruction body is only #{String.length(trimmed)} characters — not enough " <>
              "procedure to be worth invoking. " <>
              "Fix: write the concrete steps/commands (at least #{@min_body_len} characters)."
          )
        ]

      bytes > @max_body_bytes ->
        [
          finding(
            :warning,
            :body_too_large,
            path,
            "the instruction body is #{bytes} bytes; it is loaded whole into context on invoke, " <>
              "which at this size costs roughly #{div(bytes, 4)} tokens per use. " <>
              "Fix: split the detail into reference files the skill tells the agent to read on demand."
          )
        ]

      true ->
        []
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp finding(severity, rule, path, message) do
    %{severity: severity, rule: rule, path: path, message: message}
  end

  defp first_present(meta, keys) do
    Enum.find_value(keys, fn k ->
      case Map.get(meta, k) do
        nil -> nil
        "" -> nil
        v -> v
      end
    end)
  end

  # Cheap typo detector: same first letter and edit-distance-ish length match.
  # Used only to enrich a message, never to decide severity.
  defp near_miss(candidates, target) do
    t = String.downcase(to_string(target))

    Enum.find(candidates, fn c ->
      c = String.downcase(to_string(c))

      c != t and String.first(c) == String.first(t) and
        abs(String.length(c) - String.length(t)) <= 2 and
        String.jaro_distance(c, t) >= 0.8
    end)
  end

  defp slugify(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "my-skill"
      s -> String.slice(s, 0, @max_name_len)
    end
  end

  defp inspect_type(v) when is_map(v), do: "a mapping"
  defp inspect_type(v) when is_list(v), do: "a list containing non-string items"
  defp inspect_type(v) when is_boolean(v), do: "a boolean"
  defp inspect_type(v) when is_number(v), do: "a number"
  defp inspect_type(_), do: "an unsupported value"

  defp yaml_reason(%{message: msg}) when is_binary(msg), do: msg
  defp yaml_reason(reason) when is_binary(reason), do: reason
  defp yaml_reason(reason), do: inspect(reason)

  defp severity_rank(:error), do: 0
  defp severity_rank(_), do: 1

  defp sev_label(:error), do: "ERROR"
  defp sev_label(:warning), do: "WARNING"
end
