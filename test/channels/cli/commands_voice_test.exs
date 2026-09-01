defmodule OptimalSystemAgent.Channels.CLI.CommandsVoiceTest do
  @moduledoc """
  /voice must be registered in the unified command registry with a
  description that states both halves of the contract: it binds to THIS
  session, and `off` closes it. Deliberately does not reference the
  Agent.Voice module so this file compiles against trees that predate it —
  which is what makes the red run at origin/main meaningful.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Channels.CLI.Commands

  test "/voice is registered with an honest description" do
    {_name, desc} =
      Enum.find(Commands.list_with_descriptions(), fn {n, _} -> n == "voice" end)

    assert is_binary(desc)
    assert desc =~ "session", "help line must say the orb binds to this session"
    assert desc =~ "off", "help line must say how to close it"
  end
end
