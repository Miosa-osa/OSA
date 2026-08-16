defmodule OptimalSystemAgent.Agent.FastPath do
  @moduledoc """
  Capability-preserving acceleration helpers for `/fast` mode.

  Fast mode should not make OSA weaker. This module reduces wall-clock latency
  by prefetching cheap context in parallel and by presenting a relevant tool set
  first while keeping discovery/delegation tools available as escape hatches.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Effort

  @prefetch_timeout_ms 120
  @fallback_tools ~w(tool_search skill_view delegate orchestrate ask_user task_write file_read shell_execute)

  @intent_tools %{
    code:
      ~w(file_read file_write file_edit multi_file_edit shell_execute git grep diff task_write),
    search: ~w(file_read grep glob codebase_explore semantic_search web_search tool_search),
    git: ~w(git diff shell_execute file_read),
    schedule: ~w(cron remote_trigger subscribe_pr task_write),
    browser: ~w(browser computer_use launch_app),
    memory: ~w(memory_save memory_recall semantic_search),
    team: ~w(delegate orchestrate team_create list_agents send_message task_write),
    notebook: ~w(notebook_edit file_read file_write)
  }

  @doc "Start cheap speculative context prefetches for the first fast-mode iteration."
  @spec prefetch_async(map()) :: Task.t() | nil
  def prefetch_async(%{iteration: 0} = state) do
    if Effort.fast_mode?() do
      Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn -> prefetch(state) end)
    end
  rescue
    e ->
      Logger.debug("[FastPath] prefetch unavailable: #{Exception.message(e)}")
      nil
  end

  def prefetch_async(_state), do: nil

  @doc "Consume a prefetch task without blocking the hot path for long."
  @spec await_prefetch(Task.t() | nil) :: map() | nil
  def await_prefetch(nil), do: nil

  def await_prefetch(task) do
    case Task.yield(task, @prefetch_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} when is_map(result) -> result
      _ -> nil
    end
  end

  @doc "Inject fast-path context into the already-built LLM context."
  @spec inject_context(map(), map() | nil) :: map()
  def inject_context(context, nil), do: context
  def inject_context(context, prefetch) when prefetch == %{}, do: context

  def inject_context(%{messages: messages} = context, prefetch) do
    content = format_prefetch(prefetch)

    if content == "" do
      context
    else
      %{context | messages: messages ++ [%{role: "system", content: content}]}
    end
  end

  @doc """
  Select a relevant first-pass tool set for fast mode.

  This preserves capability by always retaining `tool_search`/delegation-style
  escape hatches and by falling back to the original tool list when intent is
  unclear.
  """
  @spec select_tools(list(), map()) :: list()
  def select_tools(tools, state) when is_list(tools) do
    if Effort.fast_mode?() do
      message = latest_user_message(state)
      intents = classify_intents(message)

      if intents == [] do
        report_selection(tools, tools, [], :no_intent)
        tools
      else
        wanted_names =
          @fallback_tools ++
            Enum.flat_map(intents, &Map.get(@intent_tools, &1, []))

        wanted =
          wanted_names
          |> Enum.uniq()
          |> MapSet.new()

        by_name =
          Map.new(tools, fn tool ->
            {tool_name(tool), tool}
          end)

        selected =
          wanted_names
          |> Enum.uniq()
          |> Enum.filter(&MapSet.member?(wanted, &1))
          |> Enum.flat_map(fn name ->
            case Map.fetch(by_name, name) do
              {:ok, tool} -> [tool]
              :error -> []
            end
          end)

        cap = Effort.tool_budget()

        cond do
          selected == [] ->
            report_selection(tools, tools, intents, :no_match_fallback)
            tools

          length(selected) <= cap ->
            report_selection(tools, selected, intents, :intent_match)
            selected

          true ->
            capped = Enum.take(selected, cap)
            report_selection(tools, capped, intents, :intent_match_capped)
            capped
        end
      end
    else
      tools
    end
  end

  def select_tools(tools, _state), do: tools

  # The only stage in `Loop.ToolFilter.filter/1` that logged NOTHING. Every
  # other pass either announces its narrowing or is a safety gate whose removals
  # are re-applied by construction; this one silently dropped the majority of
  # the toolbox on a keyword guess and left no trace of which tools went or why.
  # With the intent classifier being what it is (see `classify_intents/1`), a
  # wrong guess is not rare, and "the model did not call the tool" is
  # indistinguishable from "the model was never offered the tool".
  defp report_selection(before, after_tools, intents, source) do
    dropped = length(before) - length(after_tools)

    :telemetry.execute(
      [:osa, :fast_path, :tool_selection],
      %{before: length(before), after: length(after_tools), dropped: max(dropped, 0)},
      %{intents: intents, reason: source}
    )

    if dropped > 0 do
      names =
        MapSet.difference(MapSet.new(before, &tool_name/1), MapSet.new(after_tools, &tool_name/1))

      key = {source, intents, dropped}

      if Process.get(:osa_fast_path_tools) != key do
        Process.put(:osa_fast_path_tools, key)

        Logger.info(
          "[FastPath] fast mode narrowed the toolbox #{length(before)} → " <>
            "#{length(after_tools)} on intents #{inspect(intents)} (#{source}); withheld: " <>
            Enum.join(Enum.sort(names), ", ")
        )
      end
    end

    :ok
  end

  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(%{name: name}) when is_atom(name), do: Atom.to_string(name)
  defp tool_name(_tool), do: ""

  @doc """
  Which coarse intents a user message matches.

  ## Word boundaries, not substrings

  This used `String.contains?/2`, so every keyword matched anywhere inside any
  longer word. `"code"` fires on *en**code***, *de**code***, *uni**code***,
  *bar**code***; `"test"` on *la**test***, *con**test***, *pro**test***;
  `"git"` on *di**git***, *le**git***, *lo**git***; `"ui"` on *b**ui**ld*,
  *req**ui**re*, *g**ui**de*; `"agent"` on *management*… no, but `"team"` fires
  on *s**team***, and `"pr"` on *every word containing "pr"* — **pr**int,
  ap**pr**oach, ex**pr**ession, com**pr**ess.

  On its own a spurious intent only widens the tool set, which is harmless. The
  damage is at the other end: `select_tools/2` takes the union of the matched
  intents' tool lists and then **truncates to `Effort.tool_budget()`** in the
  fixed order those lists are written in. A phantom intent therefore pushes real
  tools off the end of the cap — a message saying "print the expression" scores
  `:git` (from "pr") and can lose `file_read` to `diff`. That is the shape this
  sweep is about: a heuristic correct for the word, applied to every substring
  of every word, silently removing capability.

  ## The rule

  Tokenize on `[a-z0-9]+` — which also splits `cron_test.exs` into `cron`,
  `test`, `exs` — then a keyword matches a token when:

    * the token **equals** it, or
    * the keyword is **4+ characters and the token starts with it**.

  The prefix arm keeps the inflections users actually type (*schedule* →
  *scheduler*, *test* → *tests*, *commit* → *commits*, *file* → *files*) which a
  strict equality rule would lose. The length gate is what stops it becoming the
  old bug again: the damaging keywords are the short ones. `"pr"` and `"ui"` are
  acronyms, not word stems — a token is either that acronym or it is not — so
  they match exactly and *print* and *build* no longer score. And a 4+ prefix
  is specific enough that *encode* still does not start with *code*.
  """
  @spec classify_intents(term()) :: [atom()]
  def classify_intents(message) when is_binary(message) do
    words =
      message
      |> String.downcase()
      |> then(&Regex.scan(~r/[a-z0-9]+/, &1))
      |> List.flatten()
      |> MapSet.new()

    [
      {:code, ~w(code bug fix build implement refactor test file module compile error)},
      {:search, ~w(search find inspect audit explore locate where grep)},
      {:git, ~w(git commit diff branch pr status staged)},
      {:schedule, ~w(schedule cron reminder recurring daily weekly trigger)},
      {:browser, ~w(browser website webpage click ui screen computer)},
      {:memory, ~w(memory remember recall preference learned context)},
      {:team, ~w(agent agents delegate team swarm parallel subagent)},
      {:notebook, ~w(notebook cell jupyter)}
    ]
    |> Enum.flat_map(fn {intent, keywords} ->
      if Enum.any?(keywords, &keyword_hit?(&1, words)), do: [intent], else: []
    end)
  end

  # 4 characters is the shortest keyword for which a prefix match is safe here.
  # Below it the keywords are acronyms (`pr`, `ui`, `git`) whose prefixes are
  # common word openings — matching those is what made `print` score `:git`.
  @min_prefix_keyword 4

  defp keyword_hit?(keyword, words) do
    MapSet.member?(words, keyword) or
      (String.length(keyword) >= @min_prefix_keyword and
         Enum.any?(words, &String.starts_with?(&1, keyword)))
  end

  def classify_intents(_message), do: []

  defp prefetch(state) do
    cwd = working_dir(state)

    [
      git_status: fn -> git(cwd, ["status", "--short"]) end,
      git_changed: fn -> git(cwd, ["diff", "--name-only", "HEAD"]) end,
      file_hints: fn -> file_hints(latest_user_message(state), cwd) end
    ]
    |> Task.async_stream(fn {key, fun} -> {key, safe_call(fun)} end,
      timeout: @prefetch_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {key, value}}, acc when value not in [nil, "", []] -> Map.put(acc, key, value)
      _other, acc -> acc
    end)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  end

  defp git(cwd, args) do
    case OptimalSystemAgent.Git.cmd(args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> truncate(2_000)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp file_hints(message, cwd) when is_binary(message) do
    Regex.scan(~r/[\w\.\/-]+\.(ex|exs|js|ts|tsx|jsx|rs|py|go|md|json|yml|yaml)/, message)
    |> Enum.map(&List.first/1)
    |> Enum.uniq()
    |> Enum.filter(fn path -> File.exists?(Path.expand(path, cwd)) end)
    |> Enum.take(8)
  end

  defp file_hints(_message, _cwd), do: []

  defp latest_user_message(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> to_string(msg[:role] || msg["role"]) == "user" end)
    |> case do
      nil -> ""
      msg -> to_string(msg[:content] || msg["content"] || "")
    end
  end

  defp latest_user_message(_state), do: ""

  defp working_dir(state) do
    state
    |> Map.get(:working_dir)
    |> case do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> File.cwd!()
    end
  rescue
    _ -> "."
  end

  defp format_prefetch(prefetch) do
    parts =
      [
        format_block("Git status", Map.get(prefetch, :git_status)),
        format_block("Changed files", Map.get(prefetch, :git_changed)),
        format_file_hints(Map.get(prefetch, :file_hints))
      ]
      |> Enum.reject(&(&1 == ""))

    if parts == [] do
      ""
    else
      "[Fast path prefetch]\n" <> Enum.join(parts, "\n")
    end
  end

  defp format_block(_label, nil), do: ""
  defp format_block(_label, ""), do: ""
  defp format_block(label, value), do: "#{label}:\n#{value}"

  defp format_file_hints(nil), do: ""
  defp format_file_hints([]), do: ""
  defp format_file_hints(paths), do: "Mentioned files found:\n" <> Enum.join(paths, "\n")

  defp truncate(text, max) when byte_size(text) > max, do: binary_part(text, 0, max) <> "\n..."
  defp truncate(text, _max), do: text
end
