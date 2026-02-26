defmodule Mix.Tasks.Osa.Chat do
  @moduledoc """
  Start an interactive CLI chat session with the agent.

  Usage: mix osa.chat
  """
  use Mix.Task

  @shortdoc "Start interactive CLI chat"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    OptimalSystemAgent.Channels.CLI.start()
  end
end
