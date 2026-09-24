defmodule OptimalSystemAgent.Tools.Builtins.ExpandOutput do
  @moduledoc """
  `expand_output` — the retrieval half of "summaries in context, full output
  on demand".

  Three separate mechanisms offload a tool result's full content to disk and
  leave a compact summary in its place: `ToolResultStorage.apply_budget/4`
  (head+tail+key-lines preview), `ToolExecutor.spill_or_truncate/3` (the last
  cut before a result enters the transcript), and `ContextCollapse`'s
  oversized-message trim. All three write into the SAME `~/.osa/tool-results`
  directory and now all three name a short `handle` (the bare filename)
  alongside their note.

  This tool is the one place that reads any of them back — by handle or by
  the full path from the note — with either a line range or a grep pattern,
  so the model does not have to reach for generic `file_read`/`file_grep` (or
  guess an offset) to look at something it already knows is right there.

  Deferred (discoverable via `tool_search`): most turns never need this, so
  it does not belong in the default toolbox schema sent on every request.
  """

  @behaviour MiosaTools.Behaviour

  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  def should_defer?, do: true

  @impl true
  def name, do: "expand_output"

  @impl true
  def description do
    """
    Read back the full content of a tool result that was previously offloaded to disk — \
    identified by the `Handle:` (or full path) named in its "Full output written to ..." / \
    "saved at ..." / "saved to ..." note.

    Returns either a bounded line range (`offset`/`limit`) or, with `grep`, only the \
    matching lines with their line numbers. Use this instead of `file_read`/`file_grep` \
    when the content in question is a tool-result handle rather than a project file — it \
    resolves bare handles directly and never reads anything outside the tool-results store.
    """
    |> String.trim()
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "handle" => %{
          "type" => "string",
          "description" =>
            "The handle (bare filename) or full path named in a tool result's offload note."
        },
        "offset" => %{
          "type" => "integer",
          "description" => "1-based line number to start from. Ignored when `grep` is given."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max lines to return. Default 200."
        },
        "grep" => %{
          "type" => "string",
          "description" =>
            "Return only lines matching this pattern (regex, or a literal substring if it " <>
              "does not compile as one), each prefixed with its line number."
        }
      },
      "required" => ["handle"]
    }
  end

  @impl true
  def execute(%{"handle" => handle} = args) when is_binary(handle) do
    opts =
      []
      |> maybe_put(:offset, args["offset"])
      |> maybe_put(:limit, args["limit"])
      |> maybe_put(:grep, args["grep"])

    ToolResultStorage.expand(handle, opts)
  end

  def execute(%{"handle" => other}),
    do: {:error, "handle must be a string, got #{inspect(other)}"}

  def execute(_), do: {:error, "Missing required parameter: handle"}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
