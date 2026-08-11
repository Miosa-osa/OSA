defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_read`.

  Three-stage pipeline:
    * `validate/2`            — type checks input shape (cheap)
    * `check_permissions/2`   — path allowlist + sensitive-file deny
    * `execute/2`              — actual file read

  Logic was moved verbatim from the original `file_read.ex` (allowlist check,
  symlink resolution, image handling, range read). No semantic changes
  in Phase 1 — just relocation + permission/validation split.
  """

  import Bitwise, only: [band: 2]

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Constants
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Lines
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Magic
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Messages
  alias OptimalSystemAgent.Tools.Builtins.FileRead.PathResolve
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  # POSIX st_mode file-type mask and the type bits it selects. Used to refuse
  # FIFOs, sockets and device nodes from `stat` alone — see `special_kind/1`.
  @s_ifmt 0o170000
  @s_ififo 0o010000
  @s_ifchr 0o020000
  @s_ifblk 0o060000
  @s_ifsock 0o140000

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path} = input, _ctx) when is_binary(path),
    do: {:ok, input}

  def validate(%{"path" => _}, _ctx),
    do: {:error, "path must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    expanded = path |> Path.expand() |> resolve_real_path()

    cond do
      sensitive?(expanded) ->
        {:deny, "Access denied: #{path} is a sensitive system file"}

      not allowed?(expanded) ->
        {:deny, "Access denied: #{path} is outside allowed read paths"}

      true ->
        {:allow, input}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:ok, {:image, map()}} | {:error, String.t()}
  def execute(%{"path" => path} = input, ctx) do
    result = do_read(input)

    # Record read-state for read-before-edit / stale-write enforcement (P0-1).
    # Only successful reads of an actual file are recorded; canonical() inside
    # FileState re-stats the path, so a directory/enoent that slipped through is
    # a harmless no-op.
    if match?({:ok, _}, result) do
      FileState.record_read(session_id(ctx), resolve_target(path))
    end

    result
  end

  # Single source of truth for "which path on disk does this input name?".
  #
  # `execute/2` and `do_read/1` must agree, or a read rescued by Unicode
  # normalisation would be recorded against the un-normalised name and the
  # subsequent `file_edit` would be rejected as unread. Symlinks are resolved
  # both before and after normalisation: before, so security checks see the real
  # target; after, because the rescued name may itself be a symlink.
  defp resolve_target(path) do
    path
    |> Path.expand()
    |> resolve_real_path()
    |> PathResolve.resolve()
    |> resolve_real_path()
  end

  defp do_read(%{"path" => path} = input) do
    literal = path |> Path.expand() |> resolve_real_path()
    expanded = resolve_target(path)
    offset = input["offset"]
    limit = input["limit"]
    ext = expanded |> Path.extname() |> String.downcase()

    cond do
      # A Unicode-normalisation rescue must not become an allowlist bypass:
      # `check_permissions/2` vetted the literal path, so anything the rescue
      # resolved to gets vetted here too before a single byte is read.
      expanded != literal and (sensitive?(expanded) or not allowed?(expanded)) ->
        {:error, Messages.denied_after_normalisation(path, expanded)}

      # Pre-flight: surface a clear actionable error when the model points
      # `file_read` at a directory or a non-existent path. Without this,
      # the model gets back raw `:eisdir` / `:enoent` and tends to retry the
      # same failing call instead of switching tools.
      File.dir?(expanded) ->
        {:error, Messages.directory(path)}

      not File.exists?(expanded) ->
        {:error, Messages.missing(path, literal)}

      # Stat-based, before any `open`. A FIFO with no writer blocks forever,
      # which presents as a hung agent rather than a failed tool call — the one
      # outcome that carries no diagnostic whatsoever.
      kind = special_kind(expanded) ->
        {:error, Messages.special_file(path, kind)}

      # "Empty" and "offset past the end" both look like "nothing here" if they
      # share a message. They do not share one.
      empty?(expanded) ->
        {:ok, Messages.empty_file(path)}

      ext in Constants.image_extensions() ->
        read_image(expanded, path, ext)

      binary_verdict = binary_verdict(expanded) ->
        {:error, Messages.binary(path, binary_verdict)}

      offset || limit ->
        read_with_range(expanded, path, offset, limit)

      too_large?(expanded) ->
        {mb, cap_mb} = size_report(expanded)
        {:error, Messages.too_large(path, mb, cap_mb)}

      true ->
        read_whole(expanded, path)
    end
  end

  defp read_whole(expanded, display_path) do
    case File.read(expanded) do
      {:ok, content} ->
        if String.valid?(content) do
          {:ok, Lines.clamp(content)}
        else
          # `binary_verdict/1` only sniffs the head, so a file that turns to
          # binary further in still lands here. Identify it from what we now
          # hold rather than falling back to "appears to be binary".
          {:error, Messages.binary(display_path, Magic.identify(sniff_slice(content)))}
        end

      {:error, :eisdir} ->
        {:error, Messages.directory(display_path)}

      {:error, :enoent} ->
        {:error, Messages.missing(display_path, expanded)}

      {:error, reason} ->
        {:error,
         "Cannot read #{display_path}: #{:file.format_error(reason)} (#{inspect(reason)}). " <>
           "Check the file's permissions with `shell_execute` and `ls -l #{display_path}`, " <>
           "then retry or read a different path."}
    end
  end

  # ── Stat-based guards ─────────────────────────────────────────────────

  # Returns `:fifo` / `:socket` / `:character_device` / `:block_device` /
  # `:special` for anything that is not a regular file, and `nil` otherwise.
  # `File.stat/1` follows symlinks, so a symlink to a regular file is regular
  # and a symlink to a FIFO is correctly refused.
  @spec special_kind(String.t()) :: atom() | nil
  defp special_kind(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        nil

      {:ok, %File.Stat{type: :directory}} ->
        nil

      {:ok, %File.Stat{mode: mode} = stat} when is_integer(mode) and mode > 0 ->
        from_mode(band(mode, @s_ifmt)) || from_type(stat.type)

      {:ok, stat} ->
        from_type(stat.type)

      {:error, _reason} ->
        nil
    end
  end

  defp from_mode(@s_ififo), do: :fifo
  defp from_mode(@s_ifsock), do: :socket
  defp from_mode(@s_ifchr), do: :character_device
  defp from_mode(@s_ifblk), do: :block_device
  defp from_mode(_), do: nil

  # Fallback for filesystems/ports that do not report POSIX mode bits: Erlang
  # collapses FIFOs and sockets into `:other` and devices into `:device`.
  defp from_type(:device), do: :character_device
  defp from_type(:other), do: :special
  defp from_type(_), do: nil

  defp empty?(path) do
    match?({:ok, %File.Stat{size: 0}}, File.stat(path))
  end

  # Reads only the head of the file, so identifying a 2 GB core dump costs one
  # 4 KB read. Returns `nil` when the head looks like text.
  defp binary_verdict(path) do
    case sniff(path) do
      {:ok, head} ->
        case Magic.identify(head) do
          :text -> nil
          verdict -> verdict
        end

      :error ->
        nil
    end
  end

  defp sniff(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, Constants.sniff_bytes()) do
            data when is_binary(data) -> {:ok, data}
            :eof -> {:ok, ""}
            _ -> :error
          end
        after
          File.close(io)
        end

      {:error, _reason} ->
        :error
    end
  end

  defp sniff_slice(content) do
    binary_part(content, 0, min(Constants.sniff_bytes(), byte_size(content)))
  end

  # True when a whole-file read would exceed the byte cap. Slices (offset/limit)
  # never reach here, so they remain unbounded-by-lines but streamed.
  defp too_large?(expanded) do
    case File.stat(expanded) do
      {:ok, %{size: size}} -> size > Constants.max_read_bytes()
      _ -> false
    end
  end

  defp size_report(expanded) do
    mb =
      case File.stat(expanded) do
        {:ok, %{size: size}} -> Float.round(size / (1024 * 1024), 1)
        _ -> 0.0
      end

    {mb, div(Constants.max_read_bytes(), 1024 * 1024)}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  defp read_with_range(expanded, display_path, offset, limit) do
    cond do
      File.dir?(expanded) ->
        {:error, Messages.directory(display_path)}

      not File.exists?(expanded) ->
        {:error, Messages.missing(display_path, expanded)}

      true ->
        read_with_range_inner(expanded, display_path, offset, limit)
    end
  end

  defp read_with_range_inner(expanded, display_path, offset, limit) do
    drop_count = if offset && offset > 1, do: offset - 1, else: 0
    start_line = if offset && offset > 0, do: offset, else: 1

    lines =
      expanded
      |> File.stream!()
      |> Stream.drop(drop_count)
      |> then(fn stream ->
        if limit && limit > 0, do: Stream.take(stream, limit), else: stream
      end)
      |> Stream.with_index(start_line)
      |> Enum.map(fn {line, line_num} ->
        num_str = line_num |> Integer.to_string() |> String.pad_leading(5)
        clamped = line |> String.trim_trailing("\n") |> Lines.clamp_line(line_num)
        "#{num_str}| #{clamped}"
      end)
      |> Enum.join("\n")

    if lines == "" do
      # The empty file case is caught earlier and answered separately, so
      # reaching here means the file has content and the window missed it.
      # Counting is a second pass, but only on the failure path, and it turns
      # "no lines in range" into a bounded range the caller can actually use.
      {:error, Messages.past_eof(display_path, start_line, count_lines(expanded))}
    else
      {:ok, lines}
    end
  end

  defp count_lines(expanded) do
    expanded
    |> File.stream!()
    |> Enum.count()
  rescue
    _ -> 0
  end

  defp read_image(expanded, display_path, ext) do
    max_bytes = Constants.max_image_bytes()

    case File.stat(expanded) do
      {:ok, %{size: size}} when size > max_bytes ->
        {:error,
         "Image too large: #{display_path} (#{div(size, 1024)}KB, max #{div(max_bytes, 1024)}KB)"}

      {:ok, _stat} ->
        case File.read(expanded) do
          {:ok, bytes} ->
            b64 = Base.encode64(bytes)
            media_type = image_media_type(ext)
            {:ok, {:image, %{media_type: media_type, data: b64, path: display_path}}}

          {:error, reason} ->
            {:error, "Error reading image: #{reason}"}
        end

      {:error, :enoent} ->
        {:error, Messages.missing(display_path, expanded)}

      {:error, reason} ->
        {:error,
         "Cannot stat #{display_path}: #{:file.format_error(reason)} (#{inspect(reason)}). " <>
           "Check it with `shell_execute` and `ls -l #{display_path}`, then retry or read a " <>
           "different path."}
    end
  end

  defp image_media_type(".png"), do: "image/png"
  defp image_media_type(".jpg"), do: "image/jpeg"
  defp image_media_type(".jpeg"), do: "image/jpeg"
  defp image_media_type(".gif"), do: "image/gif"
  defp image_media_type(".webp"), do: "image/webp"
  defp image_media_type(".bmp"), do: "image/bmp"
  defp image_media_type(".tiff"), do: "image/tiff"
  defp image_media_type(_), do: "application/octet-stream"

  defp allowed_paths do
    configured =
      Application.get_env(
        :optimal_system_agent,
        :allowed_read_paths,
        Constants.default_allowed_paths()
      )

    Enum.map(configured, fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

  # Resolve symlinks before security checks to prevent symlink traversal.
  defp resolve_real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, real} ->
        real_str = to_string(real)
        if String.starts_with?(real_str, "/"), do: real_str, else: "/" <> real_str

      {:error, :einval} ->
        path

      {:error, _} ->
        path
    end
  end

  defp sensitive?(expanded_path) do
    Enum.any?(Constants.sensitive_paths(), fn pattern ->
      String.contains?(expanded_path, pattern)
    end) or expanded_path == subscription_store_path()
  end

  # The literal patterns above assume the credential store lives under a
  # directory named `.osa`. It usually does — but `OSA_HOME` can move it
  # anywhere, and a substring deny that silently stops applying when a user
  # relocates their config is worse than no deny at all, because nothing
  # announces it. Ask the store where it actually is.
  defp subscription_store_path do
    OptimalSystemAgent.Auth.SubscriptionStore.path()
  rescue
    _ -> "\0"
  end

  defp allowed?(expanded_path) do
    check_path =
      if String.ends_with?(expanded_path, "/"),
        do: expanded_path,
        else: expanded_path <> "/"

    Enum.any?(allowed_paths(), fn allowed ->
      String.starts_with?(check_path, allowed)
    end)
  end
end
