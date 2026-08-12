defmodule OptimalSystemAgent.Agent.Loop.UserAttachmentTrustTest do
  @moduledoc """
  The trust distinction on image ingestion.

  v1.0.79 closed a real hole — an `images` entry was an arbitrary-file-read
  primitive whose bytes went straight into an outbound provider request — by
  routing every entry through `PathPolicy.check_read/2`. That check confines
  reads to `read_roots/0`, and it made the owner's core use case impossible:

      "if I take a screenshot and I drag and drop the image, it should be able
       to take the image and access it"

  A screenshot lives in `$TMPDIR` (on macOS, `/var/folders/…`) or on the
  Desktop. It is never inside the workspace, so every drag-and-drop was
  refused with "is outside allowed paths".

  The threat model had conflated two different things:

    * a MODEL-supplied path is attacker-influenced and stays fully confined;
    * a USER-supplied attachment is explicit consent and must work from
      anywhere on the filesystem.

  Location confinement is the ONLY rule that differs. Canonicalisation, the
  sensitive-file blocklist, the byte cap, the magic-byte sniff and the
  "no such file" error apply to both. These tests pin all of that: each
  `:user` assertion fails on the pre-fix code (it denied), and each `:model`
  assertion fails if the fix ever leaks the relaxation onto the untrusted path.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Agent.Safety.PathPolicy

  # A real 1x1 PNG — magic-byte sniffing means fixtures must be genuine.
  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <>
         <<0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137>> <>
         <<0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180>> <>
         <<0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @state %{turn_count: 0, permission_tier: :read_only, session_id: nil}

  setup do
    uniq = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "osa-trust-#{uniq}")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)

    # A file directly in the OS temp directory, i.e. where a screenshot tool
    # actually drops its output — deliberately NOT under `workspace`.
    os_tmp_shot = Path.join(System.tmp_dir!(), "osa-screenshot-#{uniq}.png")
    File.write!(os_tmp_shot, @png)

    prev_read = Application.get_env(:optimal_system_agent, :allowed_read_paths)

    # Confine reads to the workspace, the knob PathPolicy already exposes. This
    # is what a real session looks like: the allowed root is the project, and
    # everything a screenshot tool produces is outside it.
    Application.put_env(:optimal_system_agent, :allowed_read_paths, [workspace])

    on_exit(fn ->
      case prev_read do
        nil -> Application.delete_env(:optimal_system_agent, :allowed_read_paths)
        p -> Application.put_env(:optimal_system_agent, :allowed_read_paths, p)
      end

      File.rm_rf(root)
      File.rm(os_tmp_shot)
    end)

    {:ok, workspace: workspace, outside: outside, os_tmp_shot: os_tmp_shot}
  end

  defp user(images), do: MessageHandler.ingest_images(images, :user)
  defp model(images), do: MessageHandler.ingest_images(images, :model)

  describe "user attachments are readable from anywhere (the regression)" do
    test "a screenshot in the OS temp directory is attached", ctx do
      assert {[block], []} = user([ctx.os_tmp_shot])
      assert block.type == "image"
      assert block.source.media_type == "image/png"
      assert block.source.data == Base.encode64(@png)
    end

    test "an arbitrary path outside the workspace is attached", ctx do
      shot = Path.join(ctx.outside, "desktop-shot.png")
      File.write!(shot, @png)

      assert {[block], []} = user([shot])
      assert block.source.media_type == "image/png"
    end

    test "build_messages/4 emits the image as a content block, not a rejection", ctx do
      messages = MessageHandler.build_messages("what is this", @state, [ctx.os_tmp_shot], :user)
      user_msg = List.last(messages)

      assert [%{type: "text", text: "what is this"}, %{type: "image"} = img] = user_msg.content
      assert img.source.media_type == "image/png"

      refute Enum.any?(messages, &(&1.role == "system" and &1.content =~ "could NOT")),
             "a user's own screenshot must not be reported as a failed attachment"
    end
  end

  describe "model-supplied paths stay confined" do
    test "a path outside the allowed root is still refused", ctx do
      shot = Path.join(ctx.outside, "secret.png")
      File.write!(shot, @png)

      assert {[], [reason]} = model([shot])
      assert reason =~ "outside allowed paths"
    end

    test "a screenshot in the OS temp directory is still refused", ctx do
      assert {[], [reason]} = model([ctx.os_tmp_shot])
      assert reason =~ "outside allowed paths"
    end

    test "a symlink inside the workspace pointing outside is still refused", ctx do
      secret = Path.join(ctx.outside, "secret.png")
      File.write!(secret, @png)
      link = Path.join(ctx.workspace, "innocent.png")
      :ok = File.ln_s(secret, link)

      assert {[], [reason]} = model([link])
      assert reason =~ "outside allowed paths"
    end

    test "an intermediate DIRECTORY symlink pointing outside is still refused", ctx do
      File.write!(Path.join(ctx.outside, "secret.png"), @png)
      linkdir = Path.join(ctx.workspace, "linkdir")
      :ok = File.ln_s(ctx.outside, linkdir)

      assert {[], [reason]} = model([Path.join(linkdir, "secret.png")])
      assert reason =~ "outside allowed paths"
    end

    test "the default source is :model — an unmarked call keeps confinement", ctx do
      assert {[], [reason]} = MessageHandler.ingest_images([ctx.os_tmp_shot])
      assert reason =~ "outside allowed paths"
    end
  end

  describe "canonicalisation still applies to user attachments" do
    test "a user symlink is read as its resolved target, not its own name", ctx do
      real = Path.join(ctx.outside, "real.png")
      File.write!(real, @png)
      link = Path.join(ctx.outside, "link.png")
      :ok = File.ln_s(real, link)

      assert {[block], []} = user([link])
      assert block.source.data == Base.encode64(@png)
    end

    test "a user symlink whose target is sensitive is refused", ctx do
      link = Path.join(ctx.outside, "innocent.png")
      :ok = File.ln_s(Path.join([System.user_home!(), ".ssh", "id_rsa"]), link)

      assert {[], [reason]} = user([link])
      assert reason =~ "sensitive"
    end
  end

  describe "rules that are not about location apply to BOTH sources" do
    test "a sensitive file is refused on the user path", _ctx do
      key = Path.join([System.user_home!(), ".ssh", "id_rsa"])

      assert {[], [reason]} = user([key])
      assert reason =~ "sensitive"
    end

    test "a sensitive file is refused on the model path", _ctx do
      key = Path.join([System.user_home!(), ".ssh", "id_rsa"])

      assert {[], [reason]} = model([key])
      assert reason =~ "sensitive"
    end

    test "a .env is refused on the user path even though it is 'just a file'", ctx do
      dotenv = Path.join(ctx.outside, ".env")
      File.write!(dotenv, "SECRET=1")

      assert {[], [reason]} = user([dotenv])
      assert reason =~ "sensitive"
    end

    test "a non-image is refused on the user path", ctx do
      notes = Path.join(ctx.outside, "notes.txt")
      File.write!(notes, "BEGIN OPENSSH PRIVATE KEY")

      assert {[], [reason]} = user([notes])
      assert reason =~ "not a supported image"
    end

    test "a non-image is refused on the model path", %{workspace: workspace} do
      notes = Path.join(workspace, "notes.txt")
      File.write!(notes, "BEGIN OPENSSH PRIVATE KEY")

      assert {[], [reason]} = model([notes])
      assert reason =~ "not a supported image"
    end

    test "the byte cap applies to a user attachment", ctx do
      prev = Application.get_env(:optimal_system_agent, :max_image_bytes)
      Application.put_env(:optimal_system_agent, :max_image_bytes, 32)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:optimal_system_agent, :max_image_bytes)
          v -> Application.put_env(:optimal_system_agent, :max_image_bytes, v)
        end
      end)

      assert {[], [reason]} = user([ctx.os_tmp_shot])
      assert reason =~ "exceeds"
    end

    test "a missing user path is a clear error, not a base64 passthrough", ctx do
      assert {[], [reason]} = user([Path.join(ctx.outside, "typo.png")])
      assert reason =~ "no such file"
    end
  end

  describe "the marker fails closed" do
    test "only the exact :user / \"user\" marker relaxes confinement" do
      assert MessageHandler.normalize_source(:user) == :user
      assert MessageHandler.normalize_source("user") == :user

      for bogus <- [nil, "", "User", "USER", :users, "model", 1, %{}, ["user"]] do
        assert MessageHandler.normalize_source(bogus) == :model,
               "#{inspect(bogus)} must not be read as a user assertion"
      end
    end

    test "an unrecognised marker is treated as model-supplied", ctx do
      assert {[], [reason]} = MessageHandler.ingest_images([ctx.os_tmp_shot], "USER")
      assert reason =~ "outside allowed paths"
    end
  end

  describe "PathPolicy.check_user_attachment/2" do
    test "allows a file outside every read root", ctx do
      assert :ok = PathPolicy.check_user_attachment(ctx.os_tmp_shot)
      refute PathPolicy.within_roots?(ctx.os_tmp_shot, PathPolicy.read_roots())
    end

    test "still denies a sensitive file" do
      assert {:deny, reason} =
               PathPolicy.check_user_attachment(
                 Path.join([System.user_home!(), ".ssh", "id_rsa"])
               )

      assert reason =~ "sensitive"
    end

    test "check_read_as/3 routes :user and :model to the two policies", ctx do
      assert :ok = PathPolicy.check_read_as(:user, ctx.os_tmp_shot, nil)
      assert {:deny, _} = PathPolicy.check_read_as(:model, ctx.os_tmp_shot, nil)
    end
  end
end
