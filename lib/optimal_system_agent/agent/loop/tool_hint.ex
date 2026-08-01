defmodule OptimalSystemAgent.Agent.Loop.ToolHint do
  @moduledoc """
  Turns a tool call's raw arguments into the one-line summary the TUI shows
  next to the tool name — in the live activity feed, in the permission dialog
  and in the finished transcript cell.

  The rule is: **show the single most identifying VALUE**. Never schema
  parameter names, never a raw JSON dump.

  Both of those shipped. The fallback clause
  (`args |> Map.keys() |> Enum.take(2)`) rendered an `ask_user` call as
  `"options, question"` and a `delegate` call as `"name, role"` — the SCHEMA's
  own field names presented as if they were values. Meanwhile the file-edit
  clause returns the full JSON argument map (the TUI's diff renderer needs
  `old_string`/`new_string`), which the live feed then printed verbatim as
  `{"new_string":"  @doc \\"Start the Compactor…` — a cell that never names the
  file it is editing. The JSON stays on the wire for the diff renderer; the TUI
  reduces it to the path for display (`util::arg_summary`).

  The key-name fallback is kept as a last resort for genuinely unknown tools,
  but every tool OSA ships should match a clause above it.
  """

  @doc """
  Summarize `args` for display. Returns `""` when nothing identifying exists.

  File-edit arguments are the one deliberate exception: they are returned as
  JSON so the TUI can render a real diff. Every other tool gets a plain string.
  """
  @spec summarize(map() | any()) :: String.t()

  # ── file_edit: full JSON, because the TUI renders a diff from it ──────
  def summarize(%{"old_string" => _, "new_string" => _} = args) do
    case Jason.encode(args) do
      {:ok, json} -> json
      _ -> Map.get(args, "path", "")
    end
  end

  # ── computer_use ─────────────────────────────────────────────────────
  def summarize(%{"action" => "screenshot"}), do: "screenshot"
  def summarize(%{"action" => "click", "x" => x, "y" => y}), do: "click (#{x}, #{y})"
  def summarize(%{"action" => "click", "target" => t}), do: "click → #{t}"

  def summarize(%{"action" => "double_click", "x" => x, "y" => y}),
    do: "double_click (#{x}, #{y})"

  def summarize(%{"action" => "type", "text" => t}), do: "type #{String.slice(t, 0, 30)}"
  def summarize(%{"action" => "key", "text" => t}), do: "key #{t}"
  def summarize(%{"action" => "scroll", "direction" => d}), do: "scroll #{d}"

  def summarize(%{"action" => "move_mouse", "x" => x, "y" => y}),
    do: "move_mouse (#{x}, #{y})"

  def summarize(%{"action" => "drag", "x" => x, "y" => y}), do: "drag (#{x}, #{y})"

  # ── task_write: the checklist cell is the ONLY place the operator learns
  # a task was created, so carry the TITLES, not the bare action verb.
  def summarize(%{"action" => "add", "title" => t}) when is_binary(t) and t != "",
    do: String.slice(t, 0, 60)

  def summarize(%{"action" => "add_multiple", "titles" => [first | rest]})
      when is_binary(first) do
    case rest do
      [] -> String.slice(first, 0, 60)
      _ -> "#{String.slice(first, 0, 44)} +#{length(rest)} more"
    end
  end

  def summarize(%{"action" => action, "title" => t})
      when is_binary(t) and t != "" and action in ["update", "start", "complete", "fail"],
      do: "#{action} #{String.slice(t, 0, 50)}"

  def summarize(%{"action" => action, "task_id" => id}) when is_binary(id) and id != "",
    do: "#{action} #{id}"

  def summarize(%{"action" => a}) when is_binary(a), do: a

  # ── file tools: the PATH is the identity ─────────────────────────────
  def summarize(%{"path" => p}) when is_binary(p) and p != "", do: p
  def summarize(%{"file_path" => p}) when is_binary(p) and p != "", do: p
  def summarize(%{"notebook_path" => p}) when is_binary(p) and p != "", do: p

  # ── shell ────────────────────────────────────────────────────────────
  def summarize(%{"command" => cmd}) when is_binary(cmd), do: String.slice(cmd, 0, 60)

  # ── search ───────────────────────────────────────────────────────────
  def summarize(%{"pattern" => p}) when is_binary(p) and p != "", do: String.slice(p, 0, 60)
  def summarize(%{"query" => q}) when is_binary(q), do: String.slice(q, 0, 60)

  # ── skills ───────────────────────────────────────────────────────────
  def summarize(%{"skill_name" => s}) when is_binary(s) and s != "", do: s

  # ── ask_user: the question, never "options, question" ────────────────
  def summarize(%{"question" => q}) when is_binary(q) and q != "",
    do: String.slice(q, 0, 60)

  # ── delegate / fleet: who is being asked ─────────────────────────────
  def summarize(%{"name" => n}) when is_binary(n) and n != "", do: n
  def summarize(%{"agent_name" => a}) when is_binary(a) and a != "", do: a
  def summarize(%{"agent" => a}) when is_binary(a) and a != "", do: a
  def summarize(%{"subagent_type" => a}) when is_binary(a) and a != "", do: a
  def summarize(%{"role" => r}) when is_binary(r) and r != "", do: r
  def summarize(%{"task" => t}) when is_binary(t) and t != "", do: String.slice(t, 0, 60)

  # ── generic free-text identifiers ────────────────────────────────────
  def summarize(%{"url" => u}) when is_binary(u) and u != "", do: String.slice(u, 0, 60)

  def summarize(%{"description" => d}) when is_binary(d) and d != "",
    do: String.slice(d, 0, 60)

  def summarize(%{"prompt" => p}) when is_binary(p) and p != "", do: String.slice(p, 0, 60)
  def summarize(%{"message" => m}) when is_binary(m) and m != "", do: String.slice(m, 0, 60)
  def summarize(%{"text" => t}) when is_binary(t) and t != "", do: String.slice(t, 0, 60)

  # ── last resort ──────────────────────────────────────────────────────
  #
  # An unknown tool with exactly ONE scalar argument: that value identifies the
  # call, so show it. With several, there is no honest single-value summary —
  # emit nothing rather than schema field names (the TUI drops the key-name
  # shape anyway, so printing it only wastes a row).
  def summarize(args) when is_map(args) and map_size(args) > 0 do
    scalars =
      args
      |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) end)
      |> Enum.reject(fn {_k, v} -> v == "" end)

    case scalars do
      [{_k, v}] -> v |> to_string() |> String.slice(0, 60)
      _ -> ""
    end
  end

  def summarize(_), do: ""
end
