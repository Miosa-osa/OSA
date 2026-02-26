defmodule OptimalSystemAgent.Agent.Memory do
  @moduledoc """
  Persistent memory — JSONL session storage + MEMORY.md consolidation.

  Each conversation session is stored as a JSONL file:
    ~/.osa/sessions/{session_id}.jsonl

  Periodic consolidation writes key insights to MEMORY.md
  for injection into the system prompt.
  """
  use GenServer
  require Logger

  @sessions_dir Application.compile_env(:optimal_system_agent, :sessions_dir, "~/.osa/sessions")

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Append a message to a session's JSONL file."
  def append(session_id, entry) when is_map(entry) do
    GenServer.cast(__MODULE__, {:append, session_id, entry})
  end

  @doc "Load a session's message history."
  def load_session(session_id) do
    GenServer.call(__MODULE__, {:load, session_id})
  end

  @doc "Save a key insight to MEMORY.md."
  def remember(content, category \\ "general") do
    GenServer.cast(__MODULE__, {:remember, content, category})
  end

  @doc "Read current MEMORY.md contents."
  def recall do
    GenServer.call(__MODULE__, :recall)
  end

  @impl true
  def init(:ok) do
    dir = Path.expand(@sessions_dir)
    File.mkdir_p!(dir)
    Logger.info("Agent.Memory started — sessions at #{dir}")
    {:ok, %{sessions_dir: dir}}
  end

  @impl true
  def handle_cast({:append, session_id, entry}, state) do
    path = session_path(state.sessions_dir, session_id)
    line = Jason.encode!(Map.put(entry, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601()))
    File.write!(path, line <> "\n", [:append, :utf8])
    {:noreply, state}
  end

  def handle_cast({:remember, content, category}, state) do
    memory_file = Path.expand("~/.osa/MEMORY.md")
    File.mkdir_p!(Path.dirname(memory_file))
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    entry = "\n## [#{category}] #{timestamp}\n#{content}\n"
    File.write!(memory_file, entry, [:append, :utf8])
    {:noreply, state}
  end

  @impl true
  def handle_call({:load, session_id}, _from, state) do
    path = session_path(state.sessions_dir, session_id)

    messages =
      if File.exists?(path) do
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, msg} -> msg
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    {:reply, messages, state}
  end

  def handle_call(:recall, _from, state) do
    memory_file = Path.expand("~/.osa/MEMORY.md")

    content =
      if File.exists?(memory_file) do
        File.read!(memory_file)
      else
        ""
      end

    {:reply, content, state}
  end

  defp session_path(dir, session_id) do
    Path.join(dir, "#{session_id}.jsonl")
  end
end
