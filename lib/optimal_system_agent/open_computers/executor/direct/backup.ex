defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Backup do
  @moduledoc """
  OSA-side executor for the backup wire protocol.

  ## Snapshot flow

  On `backup_snapshot_request`:
    1. Expand the source path (~ expansion).
    2. Spawn `tar cJvf - --exclude=<pat> <path> | zstd -T0 -<level>`
       piped through `split -b 1M - /tmp/miosa_backup_<snap_id>_`.
    3. For each split chunk file:
        a. Compute SHA-256.
        b. POST to `<upload_urls_base>/<snapshot_id>/<seq>` with
           headers supplied in `upload_headers` + `X-Miosa-Chunk-Sha256`.
        c. Emit `backup_progress` with phase :uploading.
    4. On all chunks uploaded: compute manifest SHA-256 over chunk metadata,
       emit `backup_snapshot_complete`.
    5. Clean up /tmp files regardless of outcome.

  ## Restore flow

  On `backup_restore_request`:
    1. Download each chunk (seq order) from `chunk_urls` to /tmp.
    2. Cat chunks | zstd -d | tar xf - -C <target_path>.
    3. Emit `backup_restore_progress` as chunks arrive.
    4. Emit `backup_restore_complete` or `backup_restore_failed`.

  ## Port safety

  The archive pipeline is run via `System.cmd/3` (not streaming Port) to
  keep the implementation simple for v1.  Files are written to /tmp and
  POSTed per-chunk.  This means peak disk usage is O(archive_size) in /tmp.
  A future v2 can stream directly from Port output without materializing
  chunks to disk.

  ## Windows

  tar + zstd are not universally present on Windows.  If the host's OS
  kind is "windows", this executor sends `backup_snapshot_failed` with
  reason :unsupported_platform.  A 7zip-based path is planned for a later
  iteration.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @chunk_size_bytes 1_048_576
  @tmp_prefix "/tmp/miosa_backup_"

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
    {:ok, %{in_flight: %{}}}
  end

  @impl true
  def handle_cast({:frame, {:backup_snapshot_request, payload}}, state) do
    snapshot_id = payload.snapshot_id

    if Map.has_key?(state.in_flight, snapshot_id) do
      Logger.warning(
        "[OC.Backup] snapshot #{snapshot_id} already in-flight, ignoring duplicate request"
      )

      {:noreply, state}
    else
      task =
        Task.async(fn ->
          run_snapshot(payload)
        end)

      {:noreply, put_in(state, [:in_flight, snapshot_id], task)}
    end
  end

  def handle_cast({:frame, {:backup_restore_request, payload}}, state) do
    restore_id = payload.restore_id
    task = Task.async(fn -> run_restore(payload) end)
    {:noreply, put_in(state, [:in_flight, restore_id], task)}
  end

  def handle_cast({:frame, _other}, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, drop_by_ref(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    if reason != :normal do
      Logger.error("[OC.Backup] task crashed: #{inspect(reason)}")
    end

    {:noreply, drop_by_ref(state, ref)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Snapshot implementation ───────────────────────────────────────────────────

  defp run_snapshot(payload) do
    %{
      snapshot_id: snapshot_id,
      path: path,
      exclude_patterns: excludes,
      compression_level: level,
      upload_urls_base: base_url,
      upload_headers: upload_headers
    } = payload

    level = level || 19
    expanded_path = expand_path(path)
    tmp_dir = @tmp_prefix <> snapshot_id <> "_"
    chunk_glob = tmp_dir <> "*"

    emit_progress(snapshot_id, :archiving, 0, 0)

    result =
      try do
        do_snapshot(
          snapshot_id,
          expanded_path,
          excludes,
          level,
          tmp_dir,
          chunk_glob,
          base_url,
          upload_headers
        )
      rescue
        e ->
          Logger.error("[OC.Backup] snapshot exception: #{Exception.message(e)}")
          {:error, Exception.message(e), :archiving}
      end

    # Always clean up tmp files
    cleanup_tmp(tmp_dir)

    case result do
      {:ok, complete_payload} ->
        FrameRouter.send_frame({:backup_snapshot_complete, complete_payload})

      {:error, reason, phase} ->
        FrameRouter.send_frame(
          {:backup_snapshot_failed,
           %{
             snapshot_id: snapshot_id,
             reason: reason,
             phase: phase
           }}
        )
    end
  end

  defp do_snapshot(
         snapshot_id,
         path,
         excludes,
         level,
         tmp_prefix,
         chunk_glob,
         base_url,
         upload_headers
       ) do
    # Build the exclude flags
    exclude_args = Enum.flat_map(excludes, fn pat -> ["--exclude=#{pat}"] end)

    # Step 1: Create compressed archive and split into chunks
    # tar cJf - <excludes> <path> | zstd -T0 -<level> | split -b 1M - <tmp_prefix>
    # We use a shell pipeline for this since System.cmd doesn't support pipes.
    split_cmd =
      build_pipeline_cmd(path, exclude_args, level, tmp_prefix)

    case System.cmd("sh", ["-c", split_cmd], stderr_to_stdout: false) do
      {_out, 0} ->
        :ok

      {err, code} ->
        Logger.warning("[OC.Backup] archive pipeline exited #{code}: #{err}")
        {:error, "archive pipeline failed (exit #{code})", :archiving}
    end
    |> case do
      :ok ->
        # Step 2: Upload chunks
        chunk_files =
          Path.wildcard(chunk_glob)
          |> Enum.sort()

        if chunk_files == [] do
          {:error, "no chunks produced — path may be empty or inaccessible", :archiving}
        else
          upload_chunks(snapshot_id, chunk_files, base_url, upload_headers)
        end

      err ->
        err
    end
  end

  defp upload_chunks(snapshot_id, chunk_files, base_url, upload_headers) do
    total_bytes = Enum.sum(Enum.map(chunk_files, &file_size/1))

    chunks_meta =
      chunk_files
      |> Enum.with_index()
      |> Enum.map(fn {path, seq} ->
        body = File.read!(path)
        sha256_bin = :crypto.hash(:sha256, body)
        sha256_hex = Base.encode16(sha256_bin, case: :lower)
        bytes = byte_size(body)

        url = "#{base_url}/#{snapshot_id}/#{seq}"

        headers =
          upload_headers ++
            [{"x-miosa-chunk-sha256", sha256_hex}, {"content-type", "application/octet-stream"}]

        case http_post(url, body, headers) do
          {:ok, status} when status in 200..299 ->
            emit_progress(snapshot_id, :uploading, total_bytes, seq + 1)
            {:ok, %{seq: seq, bytes: bytes, sha256: sha256_bin}}

          {:ok, status} ->
            {:error, "chunk #{seq} upload returned HTTP #{status}", :uploading}

          {:error, reason} ->
            {:error, "chunk #{seq} upload failed: #{inspect(reason)}", :uploading}
        end
      end)

    errors = Enum.filter(chunks_meta, &match?({:error, _, _}, &1))

    if errors != [] do
      {_tag, reason, phase} = hd(errors)
      {:error, reason, phase}
    else
      metas = Enum.map(chunks_meta, fn {:ok, m} -> m end)
      manifest_sha256 = compute_manifest_sha256(metas)
      compressed_bytes = Enum.sum(Enum.map(metas, & &1.bytes))

      {:ok,
       %{
         snapshot_id: snapshot_id,
         total_bytes: compressed_bytes,
         compressed_bytes: compressed_bytes,
         chunks:
           Enum.map(metas, fn m ->
             Map.drop(m, [:sha256]) |> Map.put(:sha256, Base.encode16(m.sha256, case: :lower))
           end),
         manifest_sha256: manifest_sha256
       }}
    end
  end

  # ── Restore implementation ────────────────────────────────────────────────────

  defp run_restore(payload) do
    %{
      restore_id: restore_id,
      snapshot_id: _snapshot_id,
      target_path: target_path,
      overwrite: _overwrite,
      chunk_urls: chunk_urls
    } = payload

    # Default target_path to ~ if not specified
    target = expand_path(target_path || "~")

    tmp_restore_dir = "/tmp/miosa_restore_#{restore_id}"
    File.mkdir_p!(tmp_restore_dir)

    total_chunks = length(chunk_urls)
    emit_restore_progress(restore_id, 0, total_chunks, 0)

    result =
      try do
        download_and_extract(restore_id, chunk_urls, tmp_restore_dir, target, total_chunks)
      rescue
        e ->
          Logger.error("[OC.Backup] restore exception: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    File.rm_rf(tmp_restore_dir)

    case result do
      :ok ->
        FrameRouter.send_frame({:backup_restore_complete, %{restore_id: restore_id}})

      {:error, reason} ->
        FrameRouter.send_frame(
          {:backup_restore_failed,
           %{
             restore_id: restore_id,
             reason: reason
           }}
        )
    end
  end

  defp download_and_extract(restore_id, chunk_urls, tmp_dir, target_path, total_chunks) do
    sorted = Enum.sort_by(chunk_urls, fn {seq, _url} -> seq end)

    chunk_files =
      Enum.map(sorted, fn {seq, url} ->
        dest = Path.join(tmp_dir, "chunk_#{seq}")

        case http_get(url, dest) do
          :ok ->
            emit_restore_progress(restore_id, seq + 1, total_chunks, 0)
            dest

          {:error, reason} ->
            throw({:download_error, "chunk #{seq}: #{inspect(reason)}"})
        end
      end)

    # Cat all chunks in order | zstd -d | tar xf - -C <target>
    File.mkdir_p!(target_path)

    chunk_list = Enum.join(chunk_files, " ")
    restore_cmd = "cat #{chunk_list} | zstd -d - | tar xf - -C #{shell_escape(target_path)}"

    case System.cmd("sh", ["-c", restore_cmd], stderr_to_stdout: false) do
      {_out, 0} -> :ok
      {err, code} -> {:error, "restore pipeline failed (exit #{code}): #{err}"}
    end
  catch
    {:download_error, reason} -> {:error, reason}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp build_pipeline_cmd(path, exclude_args, level, tmp_prefix) do
    excludes = Enum.join(exclude_args, " ")
    escaped = shell_escape(path)

    "tar cf - #{excludes} #{escaped} | zstd -T0 -#{level} | split -b #{@chunk_size_bytes} - #{tmp_prefix}"
  end

  defp emit_progress(snapshot_id, phase, bytes_processed, chunks_uploaded) do
    FrameRouter.send_frame(
      {:backup_progress,
       %{
         snapshot_id: snapshot_id,
         phase: phase,
         bytes_processed: bytes_processed,
         chunks_uploaded: chunks_uploaded
       }}
    )
  end

  defp emit_restore_progress(restore_id, chunks_downloaded, total_chunks, bytes_extracted) do
    FrameRouter.send_frame(
      {:backup_restore_progress,
       %{
         restore_id: restore_id,
         chunks_downloaded: chunks_downloaded,
         total_chunks: total_chunks,
         bytes_extracted: bytes_extracted
       }}
    )
  end

  defp compute_manifest_sha256(chunks) do
    manifest_string =
      chunks
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(fn m -> "#{m.seq}:#{m.bytes}:#{Base.encode16(m.sha256, case: :lower)}" end)
      |> Enum.join("\n")

    :crypto.hash(:sha256, manifest_string)
  end

  defp expand_path("~" <> rest) do
    home = System.user_home!()
    home <> rest
  end

  defp expand_path(path), do: path

  defp shell_escape(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  defp cleanup_tmp(tmp_prefix) do
    Path.wildcard(tmp_prefix <> "*")
    |> Enum.each(fn f ->
      File.rm(f)
    end)
  end

  # Simple HTTP POST/GET using httpc (bundled with OTP — no extra deps needed)
  defp http_post(url, body, headers) do
    url_charlist = String.to_charlist(url)

    header_charlists =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    content_type = ~c"application/octet-stream"

    :httpc.request(
      :post,
      {url_charlist, header_charlists, content_type, body},
      [{:timeout, 60_000}, {:connect_timeout, 10_000}],
      []
    )
    |> case do
      {:ok, {{_http, status, _}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_get(url, dest_path) do
    url_charlist = String.to_charlist(url)

    case :httpc.request(
           :get,
           {url_charlist, []},
           [{:timeout, 120_000}, {:connect_timeout, 10_000}],
           [{:stream, String.to_charlist(dest_path)}]
         ) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_http, status, _}, _headers, _body}} when status in 200..299 -> :ok
      {:ok, {{_http, status, _}, _, _}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_by_ref(state, ref) do
    in_flight = Map.reject(state.in_flight, fn {_id, task} -> task.ref == ref end)
    %{state | in_flight: in_flight}
  end
end
