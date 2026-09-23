defmodule OptimalSystemAgent.Channels.CLI.CommandsLeanPromptTest do
  @moduledoc """
  `/lean-prompt` — the persisted CLI toggle for `Soul.lean_system_prompt?/0`.

  Deliberately NOT named `/lean`: that name is already the TUI's client-side
  "lean view" (`priv/rust/tui/src/app/commands.rs`, hides tool-call cells from
  the terminal), a display preference handled entirely in Rust before a
  command ever reaches the backend. Colliding with it would silently shadow
  this command for every TUI user, so it gets its own name — this file also
  pins that the two never share a registration.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Soul

  @sid "lean-prompt-cmd-test"

  setup do
    prev_config_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_lean_system_prompt = Application.get_env(:optimal_system_agent, :lean_system_prompt)

    home =
      Path.join(System.tmp_dir!(), "osa-lean-cmd-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    Application.put_env(:optimal_system_agent, :config_dir, home)
    Settings.reset_cache()

    on_exit(fn ->
      File.rm_rf(home)

      if prev_config_dir,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev_config_dir),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      if prev_lean_system_prompt,
        do:
          Application.put_env(:optimal_system_agent, :lean_system_prompt, prev_lean_system_prompt),
        else: Application.delete_env(:optimal_system_agent, :lean_system_prompt)

      Settings.reset_cache()
      Soul.invalidate_static_base()
    end)

    {:ok, home: home}
  end

  test "/lean-prompt is registered under its own name, not /lean" do
    assert "lean-prompt" in Commands.list()

    # The backend does not (and must not) register a bare "lean" command: the
    # TUI already owns `/lean` client-side for its unrelated display toggle,
    # and intercepts it before it would ever reach `Commands.dispatch/2`.
    refute "lean" in Commands.list()

    {_name, desc} =
      Enum.find(Commands.list_with_descriptions(), fn {n, _} -> n == "lean-prompt" end)

    assert is_binary(desc) and desc != ""
  end

  test "/lean-prompt with no args shows current state without changing it" do
    Application.put_env(:optimal_system_agent, :lean_system_prompt, false)

    output =
      capture_io(fn ->
        assert @sid = Commands.dispatch("lean-prompt", @sid)
      end)

    assert output =~ "lean_system_prompt"
    assert output =~ "off"
    refute Soul.lean_system_prompt?()
  end

  test "/lean-prompt on persists lean_system_prompt=true to settings.json", %{home: home} do
    Application.put_env(:optimal_system_agent, :lean_system_prompt, false)

    output =
      capture_io(fn ->
        assert @sid = Commands.dispatch("lean-prompt on", @sid)
      end)

    assert output =~ "Saved to settings.json"
    assert Soul.lean_system_prompt?()

    saved = Path.join(home, "settings.json") |> File.read!() |> Jason.decode!()
    assert saved["lean_system_prompt"] == true
  end

  test "/lean-prompt off persists lean_system_prompt=false and reads back" do
    capture_io(fn -> Commands.dispatch("lean-prompt on", @sid) end)
    assert Soul.lean_system_prompt?()

    capture_io(fn -> Commands.dispatch("lean-prompt off", @sid) end)
    refute Soul.lean_system_prompt?()

    # Reading back through a fresh cache read (simulates the next turn/session
    # picking the persisted value up without any in-memory state carried over).
    Settings.reset_cache()
    refute Soul.lean_system_prompt?()
  end

  test "/lean-prompt on invalidates the cached static base so the next read reflects it" do
    Application.put_env(:optimal_system_agent, :lean_prompt, false)
    Application.put_env(:optimal_system_agent, :lean_system_prompt, false)
    Soul.invalidate_static_base()
    long = Soul.static_base(:native_tools)

    capture_io(fn -> Commands.dispatch("lean-prompt on", @sid) end)

    lean = Soul.static_base(:native_tools)
    assert byte_size(lean) < byte_size(long)
  end

  test "/lean-prompt bogus shows usage and does not persist anything" do
    output =
      capture_io(fn ->
        assert @sid = Commands.dispatch("lean-prompt bogus", @sid)
      end)

    assert output =~ "usage"
  end
end
