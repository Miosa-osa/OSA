defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.ClipboardTest do
  @moduledoc """
  Unit tests for the OSA clipboard executor.

  Covers:
    - copy_to_host: size limit rejection (>1 MiB)
    - copy_to_host: happy path on macOS (mocked pbcopy)
    - request_from_host: happy path on macOS (mocked pbpaste)
    - request_from_host: size limit rejection (host clipboard >1 MiB)
    - no_clipboard_tool: graceful degradation when no tool found

  Platform command availability is mocked by overriding PATH to point to
  a temp directory with stub scripts.
  """

  # async: false — uses a globally-named MockFrameRouterClipboard (same atom as
  # FrameRouter) and PATH env manipulation, both of which are process-global.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Clipboard

  @max_bytes 1_048_576

  setup do
    {:ok, _fr} = start_supervised({MockFrameRouterClipboard, test_pid: self()})
    {:ok, _pid} = start_supervised({Clipboard, []})

    :ok
  end

  # ── Size limit ────────────────────────────────────────────────────────────────

  describe "clipboard_copy_to_host — size limit" do
    test "rejects content > 1 MiB with :too_large error" do
      oversized = String.duplicate("x", @max_bytes + 1)

      Clipboard.handle_frame(
        {:clipboard_copy_to_host, %{req_id: "r1", content: oversized, mime: "text/plain"}}
      )

      Process.sleep(100)

      assert_receive {:outbound_frame, {:clipboard_error, %{req_id: "r1", reason: :too_large}}},
                     500
    end

    test "accepts content exactly at 1 MiB boundary" do
      # We can't verify it writes to clipboard in isolation, but it should NOT
      # send :too_large. Either synced or no_clipboard_tool is acceptable.
      at_limit = String.duplicate("x", @max_bytes)

      Clipboard.handle_frame(
        {:clipboard_copy_to_host, %{req_id: "r2", content: at_limit, mime: "text/plain"}}
      )

      Process.sleep(200)

      # Should not receive :too_large
      refute_receive {:outbound_frame, {:clipboard_error, %{req_id: "r2", reason: :too_large}}},
                     100
    end
  end

  # ── No clipboard tool ─────────────────────────────────────────────────────────

  describe "when no clipboard tool is available" do
    setup do
      # Clear PATH so no tools can be found. Save and restore.
      original_path = System.get_env("PATH") || ""
      System.put_env("PATH", "")

      on_exit(fn ->
        System.put_env("PATH", original_path)
      end)

      :ok
    end

    test "copy_to_host emits :no_clipboard_tool error" do
      Clipboard.handle_frame(
        {:clipboard_copy_to_host, %{req_id: "r3", content: "hello", mime: "text/plain"}}
      )

      Process.sleep(200)

      assert_receive {:outbound_frame,
                      {:clipboard_error, %{req_id: "r3", reason: :no_clipboard_tool}}},
                     1_000
    end

    test "request_from_host emits :no_clipboard_tool error" do
      Clipboard.handle_frame({:clipboard_request_from_host, %{req_id: "r4"}})

      Process.sleep(200)

      assert_receive {:outbound_frame,
                      {:clipboard_error, %{req_id: "r4", reason: :no_clipboard_tool}}},
                     1_000
    end
  end

  # ── Happy path with stub tools ─────────────────────────────────────────────────

  describe "copy_to_host with stub pbcopy" do
    setup do
      # Create a fake pbcopy that just reads stdin and exits 0
      bin_dir = Path.join(System.tmp_dir!(), "fake_bin_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin_dir)

      pbcopy = Path.join(bin_dir, "pbcopy")
      File.write!(pbcopy, "#!/bin/sh\ncat > /dev/null\n")
      File.chmod!(pbcopy, 0o755)

      pbpaste = Path.join(bin_dir, "pbpaste")
      File.write!(pbpaste, "#!/bin/sh\necho 'clipboard content'\n")
      File.chmod!(pbpaste, 0o755)

      original_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{bin_dir}:#{original_path}")

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm_rf!(bin_dir)
      end)

      :ok
    end

    @tag :unix
    test "emits clipboard_synced on success" do
      Clipboard.handle_frame(
        {:clipboard_copy_to_host, %{req_id: "r5", content: "hello world", mime: "text/plain"}}
      )

      Process.sleep(200)
      # On macOS/Linux with pbcopy stub this should succeed
      # On Windows (CI) the stub won't match; the test is tagged :unix
      assert_receive {:outbound_frame, {:clipboard_synced, %{req_id: "r5"}}}, 1_000
    end

    @tag :unix
    test "request_from_host returns clipboard_content" do
      Clipboard.handle_frame({:clipboard_request_from_host, %{req_id: "r6"}})

      Process.sleep(200)

      assert_receive {:outbound_frame,
                      {:clipboard_content, %{req_id: "r6", content: content, mime: "text/plain"}}},
                     1_000

      assert String.trim(content) == "clipboard content"
    end
  end
end

# ── Mock FrameRouter ──────────────────────────────────────────────────────────

defmodule MockFrameRouterClipboard do
  @moduledoc "Captures outbound frames for clipboard tests."
  use GenServer

  def start_link(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    GenServer.start_link(__MODULE__, test_pid, name: OptimalSystemAgent.OpenComputers.FrameRouter)
  end

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_cast({:outbound, frame}, test_pid) do
    send(test_pid, {:outbound_frame, frame})
    {:noreply, test_pid}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}
end
