defmodule Mix.Tasks.Osa.Lessons do
  @shortdoc "List, review and prune double-loop-learned lessons"

  @moduledoc """
  Reviewable surface for the lessons `OptimalSystemAgent.Learning.DoubleLoop`
  writes from a session's buffered pain events (repeated probes,
  re-verification loops, retried commands, wrong checkouts, slow searches,
  user corrections) at session end and at compaction.

      mix osa.lessons list
      mix osa.lessons list --limit 50
      mix osa.lessons prune <id>
      mix osa.lessons prune --all

  Every lesson is a normal `OptimalSystemAgent.Memory` entry with
  `category: :lesson` — it is already retrieved into future sessions the
  same way any other memory is (relevance-ranked, token-capped, see
  `OptimalSystemAgent.Agent.Context`'s `## Long-term Memory` block). This
  task is only the human-facing list/prune surface: nothing here changes how
  lessons are written or retrieved.

  `list` prints each lesson's id (for `prune`), the session it came from,
  when it was created, and the lesson text itself. `prune <id>` deletes one
  lesson; `prune --all` deletes every lesson currently listed (asks for
  confirmation unless `--yes` is given).
  """

  use Mix.Task

  alias OptimalSystemAgent.Learning.DoubleLoop

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    case argv do
      ["list" | rest] -> list(rest)
      ["prune" | rest] -> prune(rest)
      [] -> list([])
      _ -> Mix.shell().info("Usage: mix osa.lessons list [--limit N] | prune <id> | prune --all")
    end
  end

  defp list(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [limit: :integer])
    limit = Keyword.get(opts, :limit, 500)

    case DoubleLoop.list_lessons(limit) do
      {:ok, []} ->
        Mix.shell().info("No lessons recorded yet.")

      {:ok, entries} ->
        Enum.each(entries, &print_lesson/1)
        Mix.shell().info("\n#{length(entries)} lesson(s).")

      {:error, reason} ->
        Mix.shell().error("Failed to list lessons: #{inspect(reason)}")
    end
  end

  defp print_lesson(entry) do
    id = Map.get(entry, :id) || Map.get(entry, "id")
    session = Map.get(entry, :session_id) || Map.get(entry, "session_id") || "-"
    created = Map.get(entry, :created_at) || Map.get(entry, "created_at") || "-"
    content = Map.get(entry, :content) || Map.get(entry, "content") || ""

    Mix.shell().info("""

    id:      #{id}
    session: #{session}
    when:    #{created}
    lesson:  #{content}
    """)
  end

  defp prune(["--all" | rest]) do
    {opts, _rest, _invalid} = OptionParser.parse(rest, strict: [yes: :boolean])

    case DoubleLoop.list_lessons() do
      {:ok, []} ->
        Mix.shell().info("No lessons to prune.")

      {:ok, entries} ->
        confirmed? =
          Keyword.get(opts, :yes, false) or
            Mix.shell().yes?("Delete all #{length(entries)} lesson(s)?")

        if confirmed? do
          Enum.each(entries, fn entry ->
            id = Map.get(entry, :id) || Map.get(entry, "id")
            DoubleLoop.prune_lesson(id)
          end)

          Mix.shell().info("Deleted #{length(entries)} lesson(s).")
        else
          Mix.shell().info("Aborted.")
        end
    end
  end

  defp prune([id | _rest]) when is_binary(id) do
    case DoubleLoop.prune_lesson(id) do
      :ok -> Mix.shell().info("Deleted #{id}.")
      {:error, reason} -> Mix.shell().error("Failed to delete #{id}: #{inspect(reason)}")
    end
  end

  defp prune([]) do
    Mix.shell().info("Usage: mix osa.lessons prune <id> | prune --all")
  end
end
