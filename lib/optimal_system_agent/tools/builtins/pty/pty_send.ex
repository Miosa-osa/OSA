defmodule OptimalSystemAgent.Tools.Builtins.Pty.PtySend do
  @moduledoc """
  Send keystrokes to a running PTY session using vim-style key notation.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Shell.Pty.Manager
  alias OptimalSystemAgent.Tools.Builtins.Pty.Shared

  @impl true
  def name, do: "pty_send"

  @impl true
  def aliases, do: ["pty_keys"]

  @impl true
  def search_hint, do: "type keys into an interactive pty session (vim notation)"

  @impl true
  def description do
    """
    Send keystrokes to a PTY session (started with pty_start), in vim notation.

    Examples of `keys`:
      "hello<CR>"     type hello then Enter
      "<C-c>"         Ctrl+C
      "<Esc>:wq<CR>"  leave vim insert mode, write & quit
      "<Up><Up><CR>"  arrow keys
    Supported tokens: <CR>/<Enter>, <Esc>, <Tab>, <BS>, <Space>, <Del>,
    <Up>/<Down>/<Left>/<Right>, <Home>/<End>, <PageUp>/<PageDown>, <F1>..<F12>,
    <C-x> (ctrl), <M-x>/<A-x> (alt), <lt>/<gt>/<bar>/<bslash>. Plain text passes through.
    """
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session" => %{"type" => "string", "description" => "The pty session id or name."},
        "keys" => %{
          "type" => "string",
          "description" => "Keys in vim notation, e.g. \"hello<CR>\" or \"<C-c>\"."
        }
      },
      "required" => ["session", "keys"]
    }
  end

  @impl true
  def should_defer?, do: true

  @impl true
  def safety, do: :terminal

  @impl true
  def execute(input), do: run(input)

  @impl true
  def execute(input, _ctx), do: run(input)

  defp run(input) do
    with {:ok, session} <- Shared.session_id(input),
         keys when is_binary(keys) <-
           input["keys"] || {:error, "Missing required parameter: keys"},
         :ok <- Manager.send_keys(session, keys) do
      {:ok, "Sent keys to #{session}: #{inspect(keys)}"}
    else
      {:error, :not_found} ->
        {:error, "No such pty session: #{input["session"]}"}

      {:error, :not_alive} ->
        {:error, "pty session #{input["session"]} is not alive (child exited)"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
