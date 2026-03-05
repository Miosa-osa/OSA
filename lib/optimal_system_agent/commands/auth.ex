defmodule OptimalSystemAgent.Commands.Auth do
  @moduledoc """
  Authentication commands: login, logout.
  """

  @doc "Handle the `/login` command."
  def cmd_login(arg, session_id) do
    user_id = if arg == "", do: "cli_#{session_id}", else: String.trim(arg)
    token = OptimalSystemAgent.Channels.HTTP.Auth.generate_token(%{"user_id" => user_id})
    refresh = OptimalSystemAgent.Channels.HTTP.Auth.generate_refresh_token(%{"user_id" => user_id})

    auth_path = Path.expand("~/.osa/auth.json")
    File.mkdir_p!(Path.dirname(auth_path))
    auth_data = Jason.encode!(%{token: token, refresh_token: refresh, user_id: user_id})
    File.write(auth_path, auth_data)

    {:command,
     """
     Authenticated as #{user_id}
       Token expires in 15 minutes
       Refresh token valid for 7 days
       Saved to ~/.osa/auth.json

     TUI users: token is auto-loaded. CLI users: export OSA_TOKEN=#{token}
     """}
  end

  @doc "Handle the `/logout` command."
  def cmd_logout(_arg, _session_id) do
    auth_path = Path.expand("~/.osa/auth.json")
    File.rm(auth_path)
    {:command, "Logged out. Token cleared from ~/.osa/auth.json"}
  end
end
