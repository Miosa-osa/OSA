defmodule OptimalSystemAgent.Tools.Builtins.MemorySave do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "memory_save"

  @impl true
  def description do
    "Save important context to persistent long-term memory. Memories persist across sessions.\n\n" <>
    "## WHEN TO SAVE (immediately, never delay):\n" <>
    "- User preferences, corrections, decisions\n" <>
    "- Architectural choices, patterns that worked or failed\n" <>
    "- Names, project context, technical facts\n" <>
    "- When user says \"remember\", \"note\", or \"save\" — call it RIGHT THEN\n\n" <>
    "## The Iron Rule\n" <>
    "Never make mental notes. If it matters, call memory_save. " <>
    "Mental notes die when the session ends. Saying \"I'll remember that\" " <>
    "without calling a tool is LYING — the information is GONE.\n\n" <>
    "Save as you go. Don't batch. Don't wait for end-of-task. Don't ask permission."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "content" => %{
          "type" => "string",
          "description" => "The memory to save. Be specific and concise."
        },
        "category" => %{
          "type" => "string",
          "description" =>
            "Category: decision, preference, pattern, lesson, context, or project. Auto-detected if omitted.",
          "enum" => ["decision", "preference", "pattern", "lesson", "context", "project"]
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Optional tags for search"
        }
      },
      "required" => ["content"]
    }
  end

  @impl true
  def execute(%{"content" => content} = args) do
    opts =
      []
      |> maybe_add(:category, args["category"])
      |> maybe_add(:tags, args["tags"])
      |> maybe_add(:session_id, args["__session_id__"])

    case OptimalSystemAgent.Memory.save(content, opts) do
      {:ok, entry} ->
        link_count = count_links(entry)
        link_info = if link_count > 0, do: " · linked to #{link_count} memories", else: ""
        {:ok, "Saved · #{entry.category} (#{entry.scope})#{link_info}\n#{content}"}

      {:error, :duplicate} ->
        {:ok, "Already saved · memory exists with same content"}

      {:error, reason} ->
        {:error, "Failed to save memory: #{inspect(reason)}"}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, val), do: [{key, val} | opts]

  defp count_links(%{links: links}) when is_binary(links) do
    case Jason.decode(links) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp count_links(_), do: 0
end
