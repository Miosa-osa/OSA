defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Clipboard do
  @moduledoc """
  OSA-side executor for the clipboard wire protocol.

  Reads and writes the system clipboard using the best available tool
  for the current platform.

  ## Wire protocol handled

    * Inbound (MIOSA → OSA):
        `{:clipboard_copy_to_host, %{req_id, content, mime}}`
        `{:clipboard_request_from_host, %{req_id}}`

    * Outbound (OSA → MIOSA):
        `{:clipboard_synced, %{req_id}}`        — ack for copy_to_host
        `{:clipboard_content, %{req_id, content, mime}}`
        `{:clipboard_error, %{req_id, reason}}`  — :no_clipboard_tool | :permission_denied | :too_large

  ## Platform support

  | Platform | Write tool                   | Read tool                |
  |----------|------------------------------|--------------------------|
  | macOS    | `pbcopy`                     | `pbpaste`                |
  | Linux    | `xclip -selection clipboard` | `xclip -o -sel clipboard`|
  |          | or `xsel -b -i`              | or `xsel -b -o`          |
  |          | or `wl-copy` (Wayland)       | or `wl-paste`            |
  | Windows  | PowerShell `Set-Clipboard`   | PowerShell `Get-Clipboard`|

  Tools are tried in order. The first available tool wins. If none is
  found, `{:clipboard_error, %{reason: :no_clipboard_tool}}` is sent.

  ## Size limit

  Content is capped at 1 MiB on both directions. The OSA rejects oversized
  content from the host with `:too_large` before sending to MIOSA.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @max_content_bytes 1_048_576

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:frame, frame})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:frame, {:clipboard_copy_to_host, payload}}, state) do
    Task.start(fn -> do_copy_to_host(payload) end)
    {:noreply, state}
  end

  def handle_cast({:frame, {:clipboard_request_from_host, payload}}, state) do
    Task.start(fn -> do_request_from_host(payload) end)
    {:noreply, state}
  end

  def handle_cast({:frame, _other}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Clipboard write (MIOSA → host) ────────────────────────────────────────────

  defp do_copy_to_host(%{req_id: req_id, content: content} = _payload) do
    result =
      if byte_size(content) > @max_content_bytes do
        {:error, :too_large}
      else
        platform_write(content)
      end

    case result do
      :ok ->
        FrameRouter.send_frame({:clipboard_synced, %{req_id: req_id}})

      {:error, :too_large} ->
        FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :too_large}})

      {:error, :no_clipboard_tool} ->
        Logger.warning("[Clipboard] no clipboard write tool found on this host")
        FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :no_clipboard_tool}})

      {:error, :permission_denied} ->
        FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :permission_denied}})

      {:error, reason} ->
        Logger.warning("[Clipboard] write failed: #{inspect(reason)}")
        FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :no_clipboard_tool}})
    end
  rescue
    e ->
      Logger.error("[Clipboard] unexpected error in do_copy_to_host: #{inspect(e)}")
      FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :no_clipboard_tool}})
  end

  # ── Clipboard read (host → MIOSA) ─────────────────────────────────────────────

  defp do_request_from_host(%{req_id: req_id} = _payload) do
    case platform_read() do
      {:ok, content} ->
        if byte_size(content) > @max_content_bytes do
          FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :too_large}})
        else
          FrameRouter.send_frame(
            {:clipboard_content, %{req_id: req_id, content: content, mime: "text/plain"}}
          )
        end

      {:error, :no_clipboard_tool} ->
        Logger.warning("[Clipboard] no clipboard read tool found on this host")
        FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :no_clipboard_tool}})

      {:error, :permission_denied} ->
        FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :permission_denied}})

      {:error, reason} ->
        Logger.warning("[Clipboard] read failed: #{inspect(reason)}")
        FrameRouter.send_frame({:clipboard_error, %{req_id: req_id, reason: :no_clipboard_tool}})
    end
  rescue
    e ->
      Logger.error("[Clipboard] unexpected error in do_request_from_host: #{inspect(e)}")
  end

  # ── Platform dispatch ─────────────────────────────────────────────────────────

  defp platform_write(content) do
    case :os.type() do
      {:win32, _} -> windows_write(content)
      {:unix, :darwin} -> macos_write(content)
      {:unix, _} -> linux_write(content)
    end
  end

  defp platform_read do
    case :os.type() do
      {:win32, _} -> windows_read()
      {:unix, :darwin} -> macos_read()
      {:unix, _} -> linux_read()
    end
  end

  # ── macOS ─────────────────────────────────────────────────────────────────────

  defp macos_write(content) do
    case find_tool(["pbcopy"]) do
      nil -> {:error, :no_clipboard_tool}
      tool -> run_write_tool(tool, [], content)
    end
  end

  defp macos_read do
    case find_tool(["pbpaste"]) do
      nil -> {:error, :no_clipboard_tool}
      tool -> run_read_tool(tool, [])
    end
  end

  # ── Linux ─────────────────────────────────────────────────────────────────────

  defp linux_write(content) do
    cond do
      find_tool(["xclip"]) != nil ->
        run_write_tool("xclip", ["-selection", "clipboard"], content)

      find_tool(["xsel"]) != nil ->
        run_write_tool("xsel", ["--clipboard", "--input"], content)

      find_tool(["wl-copy"]) != nil ->
        run_write_tool("wl-copy", [], content)

      true ->
        {:error, :no_clipboard_tool}
    end
  end

  defp linux_read do
    cond do
      find_tool(["xclip"]) != nil ->
        run_read_tool("xclip", ["-selection", "clipboard", "-o"])

      find_tool(["xsel"]) != nil ->
        run_read_tool("xsel", ["--clipboard", "--output"])

      find_tool(["wl-paste"]) != nil ->
        run_read_tool("wl-paste", ["--no-newline"])

      true ->
        {:error, :no_clipboard_tool}
    end
  end

  # ── Windows ───────────────────────────────────────────────────────────────────

  defp windows_write(content) do
    # Escape content for PowerShell double-quoted string
    escaped = String.replace(content, "\"", "`\"")

    case find_tool(["powershell", "pwsh"]) do
      nil ->
        {:error, :no_clipboard_tool}

      tool ->
        script = "Set-Clipboard -Value \"#{escaped}\""
        run_write_tool(tool, ["-Command", script], nil)
    end
  end

  defp windows_read do
    case find_tool(["powershell", "pwsh"]) do
      nil ->
        {:error, :no_clipboard_tool}

      tool ->
        run_read_tool(tool, ["-Command", "Get-Clipboard"])
    end
  end

  # ── Tool runners ──────────────────────────────────────────────────────────────

  # Pipe content into a tool's stdin
  defp run_write_tool(tool, args, nil) do
    # No stdin — just run the command (Windows PowerShell -Command path)
    case System.cmd(tool, args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.debug("[Clipboard] #{tool} exited #{code}: #{out}")
        {:error, :permission_denied}
    end
  rescue
    _ -> {:error, :no_clipboard_tool}
  end

  defp run_write_tool(tool, args, content) when is_binary(content) do
    # Write content to a temp file, then pipe it into the tool via the shell.
    # Using a Port + Port.close race was unreliable: Port.close invalidates the
    # port reference before the :exit_status message arrives, causing a timeout.
    tmp = Path.join(System.tmp_dir!(), "osa_clip_#{System.unique_integer([:positive])}")

    # The temp file MUST be removed on EVERY exit path. The previous shape only
    # called File.rm/1 on the happy `with` branch, so a raising/exiting
    # System.cmd (rescued below), a killed task, or a non-matching File.write
    # result orphaned the file — 329 stale `osa_clip_*` files were found on one
    # long-running host. `try/after` covers the raise and normal paths alike.
    try do
      with :ok <- File.write(tmp, content) do
        exe = find_executable(tool)
        arg_str = Enum.map_join(args, " ", &"'#{String.replace(&1, "'", "'\\''")}'")
        cmd = "#{exe} #{arg_str} < #{tmp}"

        case System.cmd("sh", ["-c", cmd],
               stderr_to_stdout: true,
               env: OptimalSystemAgent.OS.Env.cmd_env()
             ) do
          {_out, 0} ->
            :ok

          {out, code} ->
            Logger.debug("[Clipboard] #{tool} exited #{code}: #{out}")
            {:error, :permission_denied}
        end
      else
        {:error, reason} ->
          Logger.debug("[Clipboard] temp write failed: #{inspect(reason)}")
          {:error, :no_clipboard_tool}
      end
    rescue
      _ -> {:error, :no_clipboard_tool}
    after
      File.rm(tmp)
    end
  end

  # Read stdout from a tool
  defp run_read_tool(tool, args) do
    case System.cmd(tool, args, stderr_to_stdout: false) do
      {output, 0} ->
        {:ok, output}

      {_output, code} ->
        Logger.debug("[Clipboard] #{tool} read exited #{code}")
        {:error, :permission_denied}
    end
  rescue
    _ -> {:error, :no_clipboard_tool}
  end

  # ── Tool discovery ────────────────────────────────────────────────────────────

  defp find_tool(names) do
    Enum.find(names, fn name ->
      find_executable(name) != nil
    end)
  end

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> nil
      path -> path
    end
  end
end
