defmodule Mix.Tasks.Osa.Chat do
  @moduledoc """
  Start an interactive CLI chat session with the agent.

  Usage: mix osa.chat
  """
  use Mix.Task

  @shortdoc "Start interactive CLI chat"

  @impl true
  def run(_args) do
    # Silence all boot logs — the CLI should start clean
    Logger.configure(level: :none)

    Mix.Task.run("app.start")

    # Restore warnings after boot
    Logger.configure(level: :warning)

    OptimalSystemAgent.Channels.CLI.start()
  end
end
