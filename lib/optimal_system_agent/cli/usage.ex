defmodule OptimalSystemAgent.CLI.Usage do
  @moduledoc """
  `osa usage` — what your account has left, and what OSA measured itself using.

  The same report the `/usage` slash command renders, available without
  starting the daemon. Like `osa auth status` this is a pure read: it never
  refreshes a token and never spends a metered request, so it can be run in a
  loop without costing anything or moving any quota it is reporting on.

      osa usage          the active provider
      osa usage all      every configured provider
  """

  alias OptimalSystemAgent.Usage
  alias OptimalSystemAgent.Usage.Render

  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(argv \\ [])

  def run([]), do: show(all: false)
  def run(["all" | _]), do: show(all: true)
  def run(["--all" | _]), do: show(all: true)
  def run(["help" | _]), do: help()
  def run(["--help" | _]), do: help()
  def run(["-h" | _]), do: help()
  def run([other | _]), do: {:error, "Unknown `osa usage` argument: #{other}"}

  defp show(opts) do
    Usage.report(Keyword.put(opts, :probe, true))
    |> Render.lines(opts)
    |> Enum.each(&IO.puts/1)

    :ok
  end

  defp help do
    IO.puts("""

      osa usage          Usage for the active provider
      osa usage all      Usage for every configured provider

      Provider-reported quota and OSA's own token count are shown separately.
      Neither is estimated: a provider that reports nothing says so.
    """)

    :ok
  end
end
