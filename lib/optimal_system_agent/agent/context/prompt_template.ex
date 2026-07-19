defmodule OptimalSystemAgent.Agent.Context.PromptTemplate do
  @moduledoc """
  Tiny conditional, tool-name-injected prompt template renderer.

  A direct port of grok-build's `prompt/template.rs` idea (`TemplateRenderer`)
  to Elixir, using the same custom delimiters so the two systems read alike:

    * `${{ tools.KEY }}` — substitutes the live, client-facing name of the tool
      registered under logical key `KEY`. If the tool is not in the supplied
      set, it falls back to `KEY` itself (the canonical name) so prose never
      breaks. Passing a live registry name (e.g. `search_tool` for a renamed
      `tool_search`) means the prompt text always matches the real toolset —
      a rename / namespace / virtualization change can never leave a stale
      name in the prompt.

    * `${%- if tools.KEY %}…${%- endif %}` — a section that renders **only**
      when a tool of that logical kind is actually active. Absent tool ⇒ the
      whole section (and any tool names inside it) drops out. This is how a
      trimmed toolset gets a trimmed, accurate prompt instead of advertising
      tools it doesn't have.

  Supported syntax (a pragmatic subset of the grok/MiniJinja surface):

      ${{ tools.KEY }}          tool-name variable
      ${{ some_flag }}          arbitrary variable from `extras`
      ${%- if COND %} … ${%- endif %}
      ${%- if COND %} … ${%- elif COND %} … ${%- else %} … ${%- endif %}

  `COND` is a boolean expression over:

      tools.KEY                 true iff KEY is present in the tools map
      some_flag                 true iff truthy in `extras`
      not <term>                negation
      <term> or <term> …        disjunction
      <term> and <term> …       conjunction

  The `-` whitespace markers (`${%-`, `-%}`) are accepted and ignored — this
  renderer does not auto-trim, so callers control layout by placing newlines
  inside or outside the conditional (which makes byte-for-byte output easy to
  reason about and test). Conditionals may nest.

  Two containers are passed at render time:

    * `tools` — `%{"logical_key" => "live_name"}`, present tools only. Membership
      drives `${%- if tools.KEY %}`; the value drives `${{ tools.KEY }}`.
    * `extras` — `%{"flag" => boolean_or_value}` for non-tool placeholders.

  Errors never crash a prompt build: a malformed template renders best-effort
  and `render/3` is wrapped so a caller can rescue to the raw template.
  """

  @marker ~r/\$\{\{.*?\}\}|\$\{%.*?%\}/s

  @doc """
  Render `template` against the `tools` (logical key → live name) map and
  optional `extras` map. Returns the rendered string.

  Fast-path: a template with no `${{`/`${%` markers is returned unchanged.
  """
  @spec render(String.t(), map(), map()) :: String.t()
  def render(template, tools, extras \\ %{}) when is_binary(template) and is_map(tools) do
    if String.contains?(template, "${{") or String.contains?(template, "${%") do
      template
      |> tokenize()
      |> parse()
      |> render_nodes(tools, extras)
      |> IO.iodata_to_binary()
    else
      template
    end
  end

  # ── Tokenizer ─────────────────────────────────────────────────────────

  defp tokenize(str) do
    matches =
      @marker
      |> Regex.scan(str, return: :index)
      |> Enum.map(fn [{s, l}] -> {s, l} end)

    build_tokens(str, matches, 0, [])
  end

  defp build_tokens(str, [], pos, acc) do
    rest = binary_part(str, pos, byte_size(str) - pos)
    Enum.reverse(add_text(acc, rest))
  end

  defp build_tokens(str, [{s, l} | tail], pos, acc) do
    pre = binary_part(str, pos, s - pos)
    marker = binary_part(str, s, l)
    acc = [classify(marker) | add_text(acc, pre)]
    build_tokens(str, tail, s + l, acc)
  end

  defp add_text(acc, ""), do: acc
  defp add_text(acc, text), do: [{:text, text} | acc]

  # Strip the 3-char opener (`${{`/`${%`) and 2-char closer (`}}`/`%}`),
  # then the optional `-` whitespace markers and surrounding spaces.
  defp classify(marker) do
    inner = binary_part(marker, 3, byte_size(marker) - 5)

    if String.starts_with?(marker, "${{") do
      {:var, String.trim(inner)}
    else
      cleaned =
        inner
        |> String.trim()
        |> String.trim_leading("-")
        |> String.trim_trailing("-")
        |> String.trim()

      {:tag, cleaned}
    end
  end

  # ── Parser (nested if/elif/else/endif) ────────────────────────────────

  defp parse(tokens) do
    {nodes, _rest} = do_parse(tokens, [], :top)
    nodes
  end

  defp do_parse([], acc, _stop), do: {Enum.reverse(acc), []}

  defp do_parse([{:tag, tag} | rest] = toks, acc, stop) do
    case tag_keyword(tag) do
      "if" ->
        {node, rest2} = parse_if(tag, rest)
        do_parse(rest2, [node | acc], stop)

      kw when kw in ["endif", "elif", "else"] ->
        if stop == :branch do
          {Enum.reverse(acc), toks}
        else
          # Stray closer at top level — drop it.
          do_parse(rest, acc, stop)
        end

      _ ->
        # Unknown tag — drop it.
        do_parse(rest, acc, stop)
    end
  end

  defp do_parse([tok | rest], acc, stop), do: do_parse(rest, [tok | acc], stop)

  defp parse_if(tag, tokens) do
    cond_str = tag_arg(tag)
    {body, rest} = do_parse(tokens, [], :branch)
    build_branches([{cond_str, body}], rest)
  end

  defp build_branches(branches, [{:tag, tag} | rest]) do
    case tag_keyword(tag) do
      "endif" ->
        {{:if, Enum.reverse(branches), []}, rest}

      "elif" ->
        {body, rest2} = do_parse(rest, [], :branch)
        build_branches([{tag_arg(tag), body} | branches], rest2)

      "else" ->
        {else_body, rest2} = do_parse(rest, [], :branch)
        rest3 = drop_endif(rest2)
        {{:if, Enum.reverse(branches), else_body}, rest3}

      _ ->
        {{:if, Enum.reverse(branches), []}, rest}
    end
  end

  defp build_branches(branches, []), do: {{:if, Enum.reverse(branches), []}, []}

  defp drop_endif([{:tag, tag} | rest]) do
    if tag_keyword(tag) == "endif", do: rest, else: [{:tag, tag} | rest]
  end

  defp drop_endif(other), do: other

  defp tag_keyword(tag), do: tag |> String.split(~r/\s+/, parts: 2) |> List.first()

  defp tag_arg(tag) do
    case String.split(tag, ~r/\s+/, parts: 2) do
      [_kw, arg] -> String.trim(arg)
      _ -> ""
    end
  end

  # ── Renderer ──────────────────────────────────────────────────────────

  defp render_nodes(nodes, tools, extras) do
    Enum.map(nodes, &render_node(&1, tools, extras))
  end

  defp render_node({:text, t}, _tools, _extras), do: t

  defp render_node({:var, v}, tools, extras), do: render_var(v, tools, extras)

  defp render_node({:if, branches, else_nodes}, tools, extras) do
    case Enum.find(branches, fn {c, _body} -> eval(c, tools, extras) end) do
      {_c, body} -> render_nodes(body, tools, extras)
      nil -> render_nodes(else_nodes, tools, extras)
    end
  end

  defp render_var("tools." <> key, tools, _extras) do
    key = String.trim(key)
    Map.get(tools, key, key)
  end

  defp render_var(name, _tools, extras) do
    case Map.get(extras, String.trim(name)) do
      nil -> ""
      val -> to_string(val)
    end
  end

  # ── Condition evaluation ──────────────────────────────────────────────

  defp eval(cond_str, tools, extras) do
    cond_str
    |> String.split(~r/\bor\b/)
    |> Enum.any?(&eval_and(&1, tools, extras))
  end

  defp eval_and(clause, tools, extras) do
    clause
    |> String.split(~r/\band\b/)
    |> Enum.all?(&eval_term(String.trim(&1), tools, extras))
  end

  defp eval_term("not " <> rest, tools, extras),
    do: not eval_term(String.trim(rest), tools, extras)

  defp eval_term("tools." <> key, tools, _extras),
    do: Map.has_key?(tools, String.trim(key))

  defp eval_term("", _tools, _extras), do: false

  defp eval_term(term, _tools, extras) do
    case Map.get(extras, String.trim(term)) do
      nil -> false
      false -> false
      _ -> true
    end
  end
end
