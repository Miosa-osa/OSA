defmodule OptimalSystemAgent.Agent.Loop.ContextTrace do
  @moduledoc """
  TEMPORARY measurement instrumentation — context composition tracing.

  Enabled only when `OSA_CONTEXT_TRACE` is set in the environment. When off,
  `dump/4` is a single `System.get_env/1` and a return.

  Writes one JSON object per provider request to
  `$OSA_CONTEXT_TRACE_FILE` (default `/tmp/osa_context_trace.jsonl`),
  breaking the assembled request down by category using the SAME estimator the
  compaction decision uses (`OptimalSystemAgent.Utils.Tokens.estimate/1`, via
  `Agent.Context.estimate_tokens/1`).

  This module is measurement scaffolding, not product code. Delete when the
  measurement is done.
  """

  alias OptimalSystemAgent.Utils.Tokens

  @default_file "/tmp/osa_context_trace.jsonl"

  @doc "True when tracing is enabled for this OS process."
  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("OSA_CONTEXT_TRACE") not in [nil, "", "0", "false"]

  @doc """
  Dump a per-request category breakdown. `messages` is the exact list handed to
  the provider; `opts` is the exact keyword list (its `:tools` is the schema
  payload).
  """
  @spec dump(String.t(), [map()], keyword(), keyword()) :: :ok
  def dump(session_id, messages, opts, extra \\ []) do
    if enabled?() do
      try do
        do_dump(session_id, messages, opts, extra)
      rescue
        e -> log_error(e)
      catch
        _, e -> log_error(e)
      end
    end

    :ok
  end

  defp log_error(e) do
    File.write(file(), "{\"trace_error\":#{inspect(inspect(e))}}\n", [:append])
    :ok
  end

  defp file, do: System.get_env("OSA_CONTEXT_TRACE_FILE") || @default_file

  defp do_dump(session_id, messages, opts, extra) do
    seq = bump(:osa_ctx_trace_seq)

    tools = Keyword.get(opts, :tools) || []
    tool_schema_json = safe_json(tools)
    tool_schema_tokens = est(tool_schema_json)

    tool_schema_breakdown =
      tools
      |> Enum.map(fn t ->
        j = safe_json(t)
        %{name: tool_name(t), tokens: est(j), bytes: byte_size(j)}
      end)
      |> Enum.sort_by(& &1.tokens, :desc)

    per_msg =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {m, i} -> classify(m) |> Map.put(:idx, i) end)

    manifest =
      Enum.map(per_msg, fn m ->
        %{
          i: m.idx,
          role: m.role,
          name: m.name,
          tokens: m.tokens,
          bytes: m.bytes,
          head: m.text |> String.replace(~r/\s+/, " ") |> String.slice(0, 90)
        }
      end)

    cat = fn name -> per_msg |> Enum.filter(&(&1.cat == name)) end
    sum = fn list -> list |> Enum.map(& &1.tokens) |> Enum.sum() end

    system = cat.(:system)
    user = cat.(:user)
    assistant = cat.(:assistant)
    tool_results = cat.(:tool_result)
    other = cat.(:other)

    # assistant messages carry two distinct payloads
    assistant_text = assistant |> Enum.map(& &1.text_tokens) |> Enum.sum()
    assistant_calls = assistant |> Enum.map(& &1.call_tokens) |> Enum.sum()

    top_tool_results =
      tool_results
      |> Enum.sort_by(& &1.tokens, :desc)
      |> Enum.take(8)
      |> Enum.map(&%{name: &1.name, tokens: &1.tokens, bytes: &1.bytes, idx: &1.idx})

    tool_by_name =
      tool_results
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {n, list} ->
        %{name: n, count: length(list), tokens: sum.(list)}
      end)
      |> Enum.sort_by(& &1.tokens, :desc)

    # Duplicate detection: identical normalized payloads appearing >1 time
    # anywhere in the request (any role). Only chunks >= 200 bytes count, so
    # boilerplate like "ok" is not reported as duplication.
    dups = duplicates(per_msg)

    total_msg_tokens = sum.(per_msg)

    record = %{
      seq: seq,
      ts: System.system_time(:millisecond),
      session_id: session_id,
      pid: inspect(self()),
      model: Keyword.get(opts, :model),
      provider: Keyword.get(opts, :provider),
      message_count: length(messages),
      tool_schema_count: length(tools),
      tokens: %{
        total_request: total_msg_tokens + tool_schema_tokens,
        messages_total: total_msg_tokens,
        tool_schemas: tool_schema_tokens,
        system: sum.(system),
        user: sum.(user),
        assistant_text: assistant_text,
        assistant_tool_calls: assistant_calls,
        tool_results: sum.(tool_results),
        other: sum.(other)
      },
      counts: %{
        system: length(system),
        user: length(user),
        assistant: length(assistant),
        tool_results: length(tool_results),
        other: length(other)
      },
      bytes: %{
        messages_total: per_msg |> Enum.map(& &1.bytes) |> Enum.sum(),
        tool_schemas: byte_size(tool_schema_json)
      },
      manifest: manifest,
      tool_schema_breakdown: tool_schema_breakdown,
      top_tool_results: top_tool_results,
      tool_results_by_name: tool_by_name,
      duplicate_payloads: dups,
      extra: Map.new(extra)
    }

    File.write(file(), safe_json(record) <> "\n", [:append])
    :ok
  end

  @doc """
  Record the provider-REPORTED usage for the request just completed, so the
  heuristic estimate above can be calibrated against ground truth.
  """
  @spec usage(String.t(), map(), keyword()) :: :ok
  def usage(session_id, usage, extra \\ []) do
    if enabled?() do
      rec = %{
        kind: "usage",
        seq: Process.get(:osa_ctx_trace_seq),
        ts: System.system_time(:millisecond),
        session_id: session_id,
        usage: normalize_usage(usage),
        extra: Map.new(extra)
      }

      File.write(file(), safe_json(rec) <> "\n", [:append])
    end

    :ok
  end

  defp normalize_usage(u) when is_map(u) do
    Map.new(u, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_usage(_), do: %{}

  defp bump(key) do
    n = (Process.get(key) || 0) + 1
    Process.put(key, n)
    n
  end

  # ── classification ────────────────────────────────────────────────────────

  defp tool_name(t) when is_map(t) do
    to_string(
      Map.get(t, :name) || Map.get(t, "name") ||
        get_in_safe(t, [:function, :name]) || get_in_safe(t, ["function", "name"]) || "?"
    )
  end

  defp tool_name(_), do: "?"

  defp get_in_safe(m, [a, b]) do
    case Map.get(m, a) do
      inner when is_map(inner) -> Map.get(inner, b)
      _ -> nil
    end
  end

  defp classify(msg) when is_map(msg) do
    role = role_of(msg)
    content = get(msg, :content)
    text = to_text(content)
    text_tokens = est(text)

    calls = get(msg, :tool_calls) || []

    call_json =
      case calls do
        [] -> ""
        list when is_list(list) -> safe_json(list)
        _ -> ""
      end

    call_tokens = est(call_json)

    cat =
      case role do
        "system" -> :system
        "user" -> :user
        "assistant" -> :assistant
        "tool" -> :tool_result
        _ -> :other
      end

    %{
      cat: cat,
      role: role,
      name: to_string(get(msg, :name) || get(msg, :tool_name) || "-"),
      tokens: text_tokens + call_tokens,
      text_tokens: text_tokens,
      call_tokens: call_tokens,
      bytes: byte_size(text) + byte_size(call_json),
      text: text,
      idx: nil
    }
  end

  defp classify(_),
    do: %{
      cat: :other,
      role: "?",
      name: "-",
      tokens: 0,
      text_tokens: 0,
      call_tokens: 0,
      bytes: 0,
      text: "",
      idx: nil
    }

  defp role_of(msg) do
    case get(msg, :role) do
      r when is_binary(r) -> r
      r when is_atom(r) and not is_nil(r) -> Atom.to_string(r)
      _ -> "?"
    end
  end

  defp get(msg, key) when is_map(msg) do
    Map.get(msg, key) || Map.get(msg, to_string(key))
  end

  # Flatten string | [blocks] content into one string for measurement.
  defp to_text(nil), do: ""
  defp to_text(s) when is_binary(s), do: s

  defp to_text(list) when is_list(list) do
    list
    |> Enum.map(fn
      b when is_binary(b) ->
        b

      b when is_map(b) ->
        Map.get(b, :text) || Map.get(b, "text") || Map.get(b, :content) ||
          Map.get(b, "content") || safe_json(b)

      other ->
        inspect(other)
    end)
    |> Enum.map(&to_text/1)
    |> Enum.join("\n")
  end

  defp to_text(other), do: inspect(other)

  defp est(""), do: 0
  defp est(s) when is_binary(s), do: Tokens.estimate(s)
  defp est(_), do: 0

  # ── duplicate detection ───────────────────────────────────────────────────

  @dup_min_bytes 200

  defp duplicates(per_msg) do
    per_msg
    |> Enum.with_index()
    |> Enum.flat_map(fn {m, i} ->
      t = normalize(m.text)
      if byte_size(t) >= @dup_min_bytes, do: [{hash(t), i, m.role, byte_size(t)}], else: []
    end)
    |> Enum.group_by(fn {h, _, _, _} -> h end)
    |> Enum.filter(fn {_, occ} -> length(occ) > 1 end)
    |> Enum.map(fn {h, occ} ->
      {_, _, _, bytes} = hd(occ)

      %{
        hash: h,
        occurrences: length(occ),
        bytes_each: bytes,
        tokens_each: div(bytes, 4),
        wasted_tokens: div(bytes, 4) * (length(occ) - 1),
        at: Enum.map(occ, fn {_, i, role, _} -> %{index: i, role: role} end)
      }
    end)
    |> Enum.sort_by(& &1.wasted_tokens, :desc)
    |> Enum.take(10)
  end

  defp normalize(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()

  defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp safe_json(term) do
    case Jason.encode(term) do
      {:ok, j} -> j
      _ -> inspect(term, limit: :infinity, printable_limit: :infinity)
    end
  end
end
