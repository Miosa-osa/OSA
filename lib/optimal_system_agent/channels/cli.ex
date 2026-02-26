defmodule OptimalSystemAgent.Channels.CLI do
  @moduledoc """
  Interactive CLI REPL channel.
  Start with: mix chat
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  def start do
    IO.puts("""
    ╔══════════════════════════════════════════════════════╗
    ║       OptimalSystemAgent — Interactive CLI           ║
    ║  Signal Theory optimized proactive AI agent          ║
    ║  Type 'exit' to quit | 'status' for system info     ║
    ╚══════════════════════════════════════════════════════╝
    """)

    session_id = "cli_#{:rand.uniform(999_999)}"
    {:ok, _pid} = Loop.start_link(session_id: session_id, channel: :cli)

    loop(session_id)
  end

  defp loop(session_id) do
    case IO.gets("you> ") do
      :eof ->
        :ok

      "exit\n" ->
        IO.puts("Goodbye.")
        :ok

      input ->
        input = String.trim(input)

        unless input == "" do
          case Loop.process_message(session_id, input) do
            {:ok, response} -> IO.puts("\nosa> #{response}\n")
            {:filtered, _signal} -> IO.puts("\n[filtered as noise]\n")
            {:error, reason} -> IO.puts("\n[error: #{reason}]\n")
          end
        end

        loop(session_id)
    end
  end
end
