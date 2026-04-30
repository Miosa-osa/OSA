defmodule OptimalSystemAgent.Sandbox.RouterUnavailableBackend do
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  def available?, do: false
  def name, do: "test unavailable"
  def execute(_command, _opts), do: {:error, "should not execute"}
  def run_file(_path, _opts), do: {:error, "should not run file"}
end

defmodule OptimalSystemAgent.Sandbox.RouterAvailableBackend do
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  def available?, do: true
  def name, do: "test available"
  def execute(command, _opts), do: {:ok, "sandbox:#{command}"}
  def run_file(path, _opts), do: {:ok, "sandbox-file:#{Path.basename(path)}"}
end

defmodule OptimalSystemAgent.Sandbox.RouterTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Sandbox.Router
  alias OptimalSystemAgent.Sandbox.RouterAvailableBackend
  alias OptimalSystemAgent.Sandbox.RouterUnavailableBackend

  @env_keys [:sandbox_backend, :sandbox_mode, :sandbox_required]

  setup do
    previous = Enum.map(@env_keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:optimal_system_agent, key, value)
        {key, :error} -> Application.delete_env(:optimal_system_agent, key)
      end)
    end)

    :ok
  end

  describe "optional mode" do
    test "keeps fallback to host when configured backend is unavailable" do
      Application.put_env(:optimal_system_agent, :sandbox_backend, RouterUnavailableBackend)
      Application.put_env(:optimal_system_agent, :sandbox_mode, :optional)

      assert Router.mode() == :optional
      assert {:ok, output} = Router.execute("printf optional-fallback")
      assert output == "optional-fallback"
    end
  end

  describe "required mode" do
    test "blocks execute when configured backend is unavailable" do
      Application.put_env(:optimal_system_agent, :sandbox_backend, RouterUnavailableBackend)
      Application.put_env(:optimal_system_agent, :sandbox_mode, :required)

      assert Router.mode() == :required
      assert Router.available?() == false
      assert {:error, message} = Router.execute("printf should-not-run")
      assert message =~ "Sandbox required"
      assert message =~ "not available"
    end

    test "blocks run_file without falling back to host" do
      Application.put_env(:optimal_system_agent, :sandbox_backend, RouterUnavailableBackend)
      Application.put_env(:optimal_system_agent, :sandbox_mode, :required)

      marker =
        Path.join(System.tmp_dir!(), "osa_sandbox_router_#{System.unique_integer([:positive])}")

      script = marker <> ".sh"

      File.write!(script, "printf ran > #{marker}\n")

      on_exit(fn ->
        File.rm(script)
        File.rm(marker)
      end)

      assert {:error, message} = Router.run_file(script)
      assert message =~ "Sandbox required"
      refute File.exists?(marker)
    end

    test "blocks explicit host backend" do
      Application.put_env(:optimal_system_agent, :sandbox_backend, :host)
      Application.put_env(:optimal_system_agent, :sandbox_mode, :required)

      assert Router.available?() == false
      assert {:error, message} = Router.execute("printf host")
      assert message =~ "host (no sandbox)"
    end

    test "uses available non-host backend" do
      Application.put_env(:optimal_system_agent, :sandbox_backend, RouterAvailableBackend)
      Application.put_env(:optimal_system_agent, :sandbox_mode, :required)

      assert Router.available?()
      assert {:ok, "sandbox:echo ok"} = Router.execute("echo ok")
    end
  end
end
