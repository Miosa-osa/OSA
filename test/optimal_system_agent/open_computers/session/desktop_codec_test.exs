defmodule OptimalSystemAgent.OpenComputers.Session.DesktopCodecTest do
  use ExUnit.Case, async: true

  test "fresh VM decodes desktop grant and owner hello without relying on unrelated module atoms" do
    frames = [
      {:hello_ok, %{host_id: "host", owner_tenant_id: "owner"}},
      {:desktop_session_grant,
       %{
         host_id: "host",
         tenant_id: "owner",
         session_id: "session",
         scope: ["desktop:stream", "desktop:control"],
         expires_at: 1_800_000_000
       }}
    ]

    source = Path.expand("lib/optimal_system_agent/open_computers/session/frame_codec.ex")
    encoded = Base.encode64(:erlang.term_to_binary(frames))

    script =
      "case OptimalSystemAgent.OpenComputers.Session.FrameCodec.decode(Base.decode64!(hd(System.argv()))) do {:ok, _} -> System.halt(0); _ -> System.halt(19) end"

    {output, status} =
      System.cmd("elixir", ["-r", source, "-e", script, encoded], stderr_to_stdout: true)

    assert status == 0, output
    unknown = Base.encode64(:erlang.term_to_binary(:untrusted_desktop_permission_atom_test_only))

    {_, rejected} =
      System.cmd("elixir", ["-r", source, "-e", script, unknown], stderr_to_stdout: true)

    assert rejected == 19
  end
end
