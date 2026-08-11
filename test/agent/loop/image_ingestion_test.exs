defmodule OptimalSystemAgent.Agent.Loop.ImageIngestionTest do
  @moduledoc """
  `MessageHandler.build_messages/3` reads image attachments off the filesystem.
  The entry is untrusted: it can be model-authored, and over
  `POST /api/v1/orchestrate` it comes straight off the request body
  (`orchestrate_routes.ex`, `images`). Before the fix the whole ingestion was

      if File.exists?(entry), do: File.read(entry) |> Base.encode64(), else: entry

  with the media type guessed from the extension (defaulting to `image/png`).
  That is an arbitrary-file-read primitive whose output is base64'd into an
  outbound provider request — `images: ["~/.ssh/id_rsa"]` exfiltrates the key —
  and a mistyped path was shipped as a bogus base64 payload rather than erroring.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.MessageHandler

  # A real 1x1 PNG. Magic-byte sniffing means a fake payload is no longer an
  # "image", so the fixtures have to be genuine.
  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <>
         <<0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137>> <>
         <<0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180>> <>
         <<0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>> <> :binary.copy(<<0>>, 64)

  @state %{turn_count: 0, permission_tier: :read_only, session_id: nil}

  setup do
    root = Path.join(System.tmp_dir!(), "osa-img-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)

    prev_read = Application.get_env(:optimal_system_agent, :allowed_read_paths)
    prev_max = Application.get_env(:optimal_system_agent, :max_image_bytes)

    # Confine reads to the workspace for the duration of the test, exactly the
    # knob PathPolicy already exposes. `outside/` is a sibling, so it is a real
    # "outside the allowed root" path on the same filesystem.
    Application.put_env(:optimal_system_agent, :allowed_read_paths, [workspace])

    on_exit(fn ->
      if prev_read do
        Application.put_env(:optimal_system_agent, :allowed_read_paths, prev_read)
      else
        Application.delete_env(:optimal_system_agent, :allowed_read_paths)
      end

      if prev_max do
        Application.put_env(:optimal_system_agent, :max_image_bytes, prev_max)
      else
        Application.delete_env(:optimal_system_agent, :max_image_bytes)
      end

      File.rm_rf(root)
    end)

    {:ok, workspace: workspace, outside: outside}
  end

  defp blocks(images), do: MessageHandler.ingest_images(images)

  describe "path confinement" do
    test "a path outside the allowed root is refused", %{outside: outside} do
      secret = Path.join(outside, "secret.png")
      File.write!(secret, @png)

      assert {[], [reason]} = blocks([secret])
      assert reason =~ "outside allowed paths"
    end

    test "a symlink inside the workspace pointing outside is refused", ctx do
      secret = Path.join(ctx.outside, "secret.png")
      File.write!(secret, @png)

      link = Path.join(ctx.workspace, "innocent.png")
      :ok = File.ln_s(secret, link)

      assert {[], [reason]} = blocks([link])
      assert reason =~ "outside allowed paths"
    end

    test "an intermediate DIRECTORY symlink pointing outside is refused too", ctx do
      secret = Path.join(ctx.outside, "secret.png")
      File.write!(secret, @png)

      linkdir = Path.join(ctx.workspace, "linkdir")
      :ok = File.ln_s(ctx.outside, linkdir)

      # The leaf is an ordinary file, so a `read_link_all`-style check would
      # pass this. PathCanon resolves every component.
      assert {[], [reason]} = blocks([Path.join(linkdir, "secret.png")])
      assert reason =~ "outside allowed paths"
    end

    test "a sensitive file is refused even when it sits inside an allowed root" do
      home = System.user_home!()
      Application.put_env(:optimal_system_agent, :allowed_read_paths, [home])

      assert {[], [reason]} = blocks([Path.join([home, ".ssh", "id_rsa"])])
      assert reason =~ "sensitive"
    end

    test "a file inside the workspace is accepted", %{workspace: workspace} do
      path = Path.join(workspace, "shot.png")
      File.write!(path, @png)

      assert {[block], []} = blocks([path])
      assert block.type == "image"
      assert block.source.media_type == "image/png"
      assert block.source.data == Base.encode64(@png)
    end
  end

  describe "content typing" do
    test "the media type comes from magic bytes, not the extension", %{workspace: workspace} do
      # A JPEG deliberately named .png — the old code trusted the extension.
      path = Path.join(workspace, "lying.png")
      File.write!(path, @jpeg)

      assert {[block], []} = blocks([path])
      assert block.source.media_type == "image/jpeg"
    end

    test "a non-image file is refused instead of being labelled image/png", %{
      workspace: workspace
    } do
      path = Path.join(workspace, "notes.txt")
      File.write!(path, "BEGIN OPENSSH PRIVATE KEY")

      assert {[], [reason]} = blocks([path])
      assert reason =~ "not a supported image"
    end

    test "an unknown extension holding a real PNG is still accepted", %{workspace: workspace} do
      path = Path.join(workspace, "clip.bin")
      File.write!(path, @png)

      assert {[block], []} = blocks([path])
      assert block.source.media_type == "image/png"
    end
  end

  describe "non-existent paths" do
    test "a missing path is a clear error, not a silent base64 passthrough", %{
      workspace: workspace
    } do
      missing = Path.join(workspace, "typo.png")

      assert {[], [reason]} = blocks([missing])
      assert reason =~ "no such file"
    end

    test "the missing path is never shipped as image data", %{workspace: workspace} do
      missing = Path.join(workspace, "typo.png")
      messages = MessageHandler.build_messages("look at this", @state, [missing])

      user = List.last(messages)
      assert user.content == "look at this"

      directive = Enum.find(messages, &(&1.role == "system" and &1.content =~ "could NOT"))
      assert directive, "the rejection must be reported to the model, not swallowed"
      assert directive.content =~ "no such file"
    end
  end

  describe "size cap" do
    test "an oversized file is refused", %{workspace: workspace} do
      Application.put_env(:optimal_system_agent, :max_image_bytes, 32)
      path = Path.join(workspace, "big.png")
      File.write!(path, @png)

      assert {[], [reason]} = blocks([path])
      assert reason =~ "exceeds"
    end
  end

  describe "inline (clipboard) bytes" do
    test "a bare base64 PNG blob is accepted and typed from its magic bytes" do
      assert {[block], []} = blocks([Base.encode64(@png)])
      assert block.source.media_type == "image/png"
      assert block.source.data == Base.encode64(@png)
    end

    test "a data: URL is accepted" do
      assert {[block], []} = blocks(["data:image/jpeg;base64," <> Base.encode64(@jpeg)])
      assert block.source.media_type == "image/jpeg"
    end

    test "a base64 blob that is not an image is refused" do
      assert {[], [reason]} = blocks([Base.encode64("this is just some text, not an image")])
      assert reason =~ "not a supported image"
    end
  end

  describe "build_messages/3 wiring" do
    test "a valid image still produces text + image blocks", %{workspace: workspace} do
      path = Path.join(workspace, "shot.png")
      File.write!(path, @png)

      messages = MessageHandler.build_messages("what is this", @state, [path])
      user = List.last(messages)

      assert [%{type: "text", text: "what is this"}, %{type: "image"} = img] = user.content
      assert img.source.media_type == "image/png"
    end

    test "no images keeps a plain string user turn" do
      messages = MessageHandler.build_messages("hello", @state, [])
      assert List.last(messages) == %{role: "user", content: "hello"}
    end
  end
end
