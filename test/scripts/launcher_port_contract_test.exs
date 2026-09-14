defmodule OptimalSystemAgent.Scripts.LauncherPortContractTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../../bin/osa", __DIR__)
  @updater Path.expand("../../bin/osa-update", __DIR__)
  @serve_task Path.expand("../../lib/mix/tasks/osa.serve.ex", __DIR__)

  test "source launcher gives the TUI and backend the same selected port" do
    source = File.read!(@launcher)

    assert source =~ ~s(_EXPLICIT_PORT="${OSA_PORT:-${OSA_HTTP_PORT:-}}")
    assert source =~ ~s(export OSA_PORT="$PORT")
    assert source =~ ~s(export OSA_HTTP_PORT="$PORT")
    assert source =~ ~s(_port_in_use "${_candidate}")
    assert source =~ ~s(ln -s "${HOME}/.osa/.env" "$OSA_HOME/.env")
  end

  test "staged-update boot probe binds the port it health-checks" do
    source = File.read!(@updater)

    assert source =~
             ~s(OSA_PORT="$port" OSA_HTTP_PORT="$port" MIX_ENV="$OSA_UPDATE_MIX_ENV" timeout 40 mix osa.serve)
  end

  test "foreground serve reports the runtime-resolved port" do
    source = File.read!(@serve_task)

    assert source =~ "OptimalSystemAgent.Net.Port.configured_http_port()"
    refute source =~ "port = Application.get_env(:optimal_system_agent, :http_port"
  end
end
