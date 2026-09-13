defmodule OptimalSystemAgent.Shell.TerminalOutputSaver do
  @max_saved_files 10

  @moduledoc """
  Save full terminal output to a file when it exceeds token/context limits.

  Pentest scans (nmap full port, nuclei with all templates, subfinder on a
  large domain) can produce thousands of lines of output — far more than fits
  in the agent's context window. When output is truncated, this module saves
  the full output to a file in the sandbox and returns a message telling the
  agent where to find it, so the agent can `file_read` specific sections later.

  ## How it works

  1. The caller checks if output was truncated (exceeds `@max_output_chars`)
  2. If truncated, `save_truncated_output/2` writes the full output to a file
  3. The file is saved under `/tmp/terminal_full_output/chat-<hash>/<timestamp>.txt`
  4. Old saved outputs are pruned (max #{@max_saved_files} per chat scope)
  5. Returns a message: "Full output saved to <path> (N chars). Read it with file_read."

  ## Usage

      # In a tool handler after running a command:
      case TerminalOutputSaver.maybe_save(output, chat_id) do
        {:saved, path, message} ->
          # Append the save message to the tool result so the agent knows
          {:ok, result <> "\\n\\n" <> message}
        :not_needed ->
          # Output fits in context, no saving needed
          {:ok, result}
      end
  """

  require Logger

  @max_output_chars 8_000
  @output_base_dir "/tmp/terminal_full_output"

  @type save_result :: {:saved, String.t(), String.t()} | :not_needed

  @doc """
  Check if output exceeds the context limit and should be saved.

      iex> TerminalOutputSaver.should_save?(String.duplicate("x", 500))
      false

      iex> TerminalOutputSaver.should_save?(String.duplicate("x", 10_000))
      true
  """
  @spec should_save?(String.t()) :: boolean()
  def should_save?(output) when is_binary(output) do
    byte_size(output) > @max_output_chars
  end

  def should_save?(_), do: false

  @doc """
  If the output is too large, save it to a file and return a save message.
  If not, return `:not_needed`.

  ## Options

    * `:scope_id` — chat/session ID for per-chat directory isolation
    * `:sandbox_fn` — function to write the file (defaults to `File.write!/2`).
      Pass a function like `fn path, content -> Sandbox.Router.execute("mkdir -p \#{Path.dirname(path)} && cat > \#{path}") end`
      to save inside a cloud sandbox instead of the local filesystem.
  """
  @spec maybe_save(String.t(), keyword()) :: save_result()
  def maybe_save(output, opts \\ []) do
    if should_save?(output) do
      path = save_output(output, opts)
      message = format_save_message(path, byte_size(output))
      {:saved, path, message}
    else
      :not_needed
    end
  end

  @doc """
  Save output to a timestamped file. Returns the file path.

  The file is saved under `#{@output_base_dir}/chat-<scope_hash>/<timestamp>.txt`.
  If `:scope_id` is not provided, uses "unscoped" as the directory key.
  """
  @spec save_output(String.t(), keyword()) :: String.t()
  def save_output(output, opts \\ []) do
    scope_id = Keyword.get(opts, :scope_id, "unscoped")
    sandbox_fn = Keyword.get(opts, :sandbox_fn)

    dir = output_directory(scope_id)
    timestamp = format_timestamp()
    path = Path.join(dir, "#{timestamp}.txt")

    if sandbox_fn do
      # Save inside a cloud sandbox — the function handles mkdir + write
      sandbox_fn.(path, output)
    else
      # Save on the local filesystem
      File.mkdir_p!(dir)
      File.write!(path, output)
    end

    # Best-effort pruning — don't let old outputs accumulate forever
    try do
      prune_old_outputs(dir, opts)
    rescue
      e -> Logger.debug("[TerminalOutputSaver] prune failed: #{Exception.message(e)}")
    end

    Logger.info("[TerminalOutputSaver] Saved #{byte_size(output)} bytes to #{path}")
    path
  end

  @doc """
  Format the save message that tells the agent where the full output is.

      iex> TerminalOutputSaver.format_save_message("/tmp/terminal_full_output/chat-abc/2026-01-01_12-00-00.txt", 15000)
      "Full output (15000 bytes) saved to /tmp/terminal_full_output/chat-abc/2026-01-01_12-00-00.txt — read it with file_read if you need the complete output."
  """
  @spec format_save_message(String.t(), non_neg_integer()) :: String.t()
  def format_save_message(path, size_bytes) do
    "Full output (#{size_bytes} bytes) saved to #{path} — read it with file_read if you need the complete output."
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp output_directory(scope_id) do
    scope_hash =
      :crypto.hash(:sha256, scope_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Path.join([@output_base_dir, "chat-#{scope_hash}"])
  end

  defp format_timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.local_time()

    "#{year}-#{pad2(month)}-#{pad2(day)}_#{pad2(hour)}-#{pad2(minute)}-#{pad2(second)}"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  defp prune_old_outputs(dir, opts) do
    sandbox_fn = Keyword.get(opts, :sandbox_fn)

    files =
      if sandbox_fn do
        # In a cloud sandbox, we'd need to list files via the sandbox API.
        # For now, skip pruning in cloud mode — the sandbox is ephemeral anyway.
        []
      else
        case File.ls(dir) do
          {:ok, entries} ->
            entries
            |> Enum.filter(&String.ends_with?(&1, ".txt"))
            |> Enum.sort()
            |> Enum.reverse()

          _ ->
            []
        end
      end

    # Delete files beyond the retention limit (keep newest #{@max_saved_files})
    stale = Enum.drop(files, @max_saved_files)

    Enum.each(stale, fn filename ->
      path = Path.join(dir, filename)
      if sandbox_fn, do: sandbox_fn.(:delete, path), else: File.rm(path)
    end)
  end

  @doc "The maximum output size (in bytes) before saving kicks in."
  @spec max_output_chars() :: non_neg_integer()
  def max_output_chars, do: @max_output_chars

  @doc "The base directory where saved outputs are stored."
  @spec output_base_dir() :: String.t()
  def output_base_dir, do: @output_base_dir
end
