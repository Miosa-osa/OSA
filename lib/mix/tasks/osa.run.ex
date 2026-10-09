defmodule Mix.Tasks.Osa.Run do
  @moduledoc """
  `osa run` from a source checkout: the headless agent, non-interactive.

      mix osa.run "Your prompt here"
      mix osa.run --format json "Explain this code"
      echo "Fix the bug" | mix osa.run --format stream-json --overdrive
      mix osa.run --resume <session id> "Continue where we left off"

  This is the same command as the release's `osagent run` and the launchers'
  `osa run`; every flag, the event schema, the approval hook and the exit codes
  are documented on `OptimalSystemAgent.CLI.Headless` and in `docs/headless.md`.
  """
  use Mix.Task

  alias OptimalSystemAgent.CLI.Headless

  @shortdoc "Run OSA in non-interactive headless mode"

  @impl true
  def run(args) do
    # Compile and load configuration (runtime.exs included) WITHOUT starting
    # the application: `Headless` marks this process headless first, so the
    # app boots without the HTTP port, channels or schedulers a daemon owns.
    Mix.Task.run("app.config", [])
    Headless.main(args)
  end

  @doc "The bytes the `text` format puts on stdout (scrubbed). See `CLI.Headless`."
  @spec text_output(term()) :: String.t()
  defdelegate text_output(response), to: Headless

  @doc "One NDJSON line, lossless and terminal-inert. See `CLI.Headless`."
  @spec json_line(map()) :: String.t()
  defdelegate json_line(map), to: Headless
end
