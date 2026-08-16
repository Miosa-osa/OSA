defmodule OptimalSystemAgent.Test.VerificationGateHelper do
  @moduledoc """
  Grants `shell_execute` allow rules for the duration of one test.

  `Verification.Loop` holds its `test_command` to the operator's permission
  rules, and `Permissions.check_detailed/2` defaults to `:ask` when no rule
  matches — which an unattended loop can only resolve as a refusal. So a test
  that wants a loop to actually RUN has to say so, the same way an operator
  would.

  That is not test scaffolding papering over an inconvenience: it is the
  contract. A test that starts a loop without calling this is asserting that
  ungranted commands are refused.
  """

  alias OptimalSystemAgent.Settings

  @doc """
  Install a settings flag file allowing exactly `commands`, restored on exit.

  Pass the raw command strings; they are wrapped as `shell_execute(<cmd>)`.
  Pass `[:any]` for an unscoped `shell_execute` rule — needed for commands the
  rule specifier cannot express, such as a multi-statement `a; b; c` line.
  Requires an `ExUnit` context (uses `ExUnit.Callbacks.on_exit/1`), so call it
  from a `setup` block or the test body.
  """
  @spec allow_commands([String.t() | :any]) :: :ok
  def allow_commands(commands) when is_list(commands) do
    flag_file =
      Path.join(
        System.tmp_dir!(),
        "osa-vloop-allow-#{System.unique_integer([:positive])}.json"
      )

    prior = Application.get_env(:optimal_system_agent, :settings_flag_path)

    File.write!(
      flag_file,
      Jason.encode!(%{
        "permissions" => %{
          "allow" =>
            Enum.map(commands, fn
              :any -> "shell_execute"
              cmd -> "shell_execute(#{cmd})"
            end)
        }
      })
    )

    Application.put_env(:optimal_system_agent, :settings_flag_path, flag_file)
    Settings.reset_cache()

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
        path -> Application.put_env(:optimal_system_agent, :settings_flag_path, path)
      end

      File.rm(flag_file)
      Settings.reset_cache()
    end)

    :ok
  end
end
