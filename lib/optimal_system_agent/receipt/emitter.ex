defmodule OptimalSystemAgent.Receipt.Emitter do
  @moduledoc """
  Async receipt emitter with periodic flush of pending receipts.

  Submits audit receipt bundles to the kernel via HTTP. Failed submissions
  are queued to disk and retried on a 60-second timer.
  """

  use GenServer
  require Logger

  @flush_interval :timer.seconds(60)
  @pending_dir Path.join(System.user_home!(), ".daemon/receipts/pending")
  @signed_dir Path.join(System.user_home!(), ".daemon/receipts/signed")

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Emit a receipt bundle asynchronously. Never blocks the caller.
  """
  def emit_async(%OptimalSystemAgent.Receipt.Bundle{} = bundle) do
    pubkey = GenServer.call(__MODULE__, :get_pubkey, 1_000)

    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      do_emit(bundle, pubkey)
    end)

    :ok
  rescue
    _ ->
      # If GenServer call fails, emit without verification
      Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
        do_emit(bundle, nil)
      end)

      :ok
  end

  @doc """
  Return the cached kernel public key, or nil if unavailable.
  """
  def get_pubkey do
    GenServer.call(__MODULE__, :get_pubkey, 1_000)
  rescue
    _ -> nil
  end

  @doc """
  Retry all pending receipts from disk.
  """
  def flush_pending do
    GenServer.cast(__MODULE__, :flush_pending)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    File.mkdir_p!(@pending_dir)
    File.mkdir_p!(@signed_dir)
    pubkey = fetch_kernel_pubkey()
    schedule_flush()
    {:ok, %{kernel_pubkey: pubkey}}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush_pending()
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_pubkey, _from, state) do
    {:reply, state.kernel_pubkey, state}
  end

  @impl true
  def handle_cast(:flush_pending, state) do
    do_flush_pending()
    {:noreply, state}
  end

  # Private

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defp do_emit(bundle, pubkey) do
    audit_map = OptimalSystemAgent.Receipt.Bundle.to_audit_map(bundle)
    kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"

    body = Jason.encode!(audit_map)

    case Req.post("#{kernel_http}/api/audit",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: %{"confirmed" => true} = resp}} ->
        sig = resp["signature"]

        attestation = resp["attestation"]

        if sig && pubkey && attestation do
          if OptimalSystemAgent.Receipt.Verifier.verify(attestation, sig, pubkey) do
            Logger.debug("[Receipt.Emitter] Signature verified for #{bundle.action_name}")
          else
            Logger.warning("[Receipt.Emitter] SIGNATURE MISMATCH for #{bundle.action_name}")
          end
        else
          Logger.debug("[Receipt.Emitter] Receipt confirmed (unsigned or no attestation) for #{bundle.action_name}")
        end

        store_signed_receipt(audit_map, resp)
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("[Receipt.Emitter] Kernel returned #{status} for receipt, queuing to pending")
        queue_to_pending(audit_map)

      {:error, reason} ->
        Logger.warning("[Receipt.Emitter] Kernel unreachable (#{inspect(reason)}), queuing to pending")
        queue_to_pending(audit_map)
    end
  rescue
    e ->
      Logger.warning("[Receipt.Emitter] Failed to emit receipt: #{inspect(e)}")
      try do
        audit_map = OptimalSystemAgent.Receipt.Bundle.to_audit_map(bundle)
        queue_to_pending(audit_map)
      rescue
        _ -> :ok
      end
  end

  defp queue_to_pending(audit_map) do
    ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    hash = :crypto.hash(:sha256, Jason.encode!(audit_map)) |> Base.encode16(case: :lower) |> String.slice(0, 12)
    filename = "#{ts}_#{hash}.json"
    path = Path.join(@pending_dir, filename)

    case File.write(path, Jason.encode!(audit_map)) do
      :ok -> Logger.debug("[Receipt.Emitter] Queued pending receipt: #{filename}")
      {:error, reason} -> Logger.error("[Receipt.Emitter] Failed to queue receipt: #{inspect(reason)}")
    end
  end

  defp do_flush_pending do
    case File.ls(@pending_dir) do
      {:ok, files} when files != [] ->
        kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"
        Logger.info("[Receipt.Emitter] Flushing #{length(files)} pending receipts")

        Enum.each(files, fn filename ->
          path = Path.join(@pending_dir, filename)

          with {:ok, body} <- File.read(path),
               {:ok, audit_map} <- Jason.decode(body),
               {:ok, %{status: 200, body: %{"confirmed" => true} = resp}} <-
                 Req.post("#{kernel_http}/api/audit",
                   body: body,
                   headers: [{"content-type", "application/json"}],
                   receive_timeout: 5_000
                 ) do
            store_signed_receipt(audit_map, resp)
            File.rm(path)
            Logger.debug("[Receipt.Emitter] Flushed pending receipt: #{filename}")
          else
            _ ->
              Logger.debug("[Receipt.Emitter] Still pending: #{filename}")
          end
        end)

      _ ->
        :ok
    end
  end

  defp fetch_kernel_pubkey do
    kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"

    case OptimalSystemAgent.Receipt.Verifier.fetch_pubkey(kernel_http) do
      {:ok, pubkey} -> pubkey
      {:error, reason} ->
        Logger.warning("[Receipt.Emitter] Could not fetch kernel pubkey: #{inspect(reason)}")
        nil
    end
  end

  defp store_signed_receipt(audit_map, resp) do
    audit_id = resp["audit_id"] || "unknown"
    receipt = Map.merge(audit_map, %{
      "kernel_response" => resp,
      "stored_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    safe_id = String.replace(audit_id, ~r/[^a-zA-Z0-9_-]/, "_")
    path = Path.join(@signed_dir, "#{safe_id}.json")

    case File.write(path, Jason.encode!(receipt, pretty: true)) do
      :ok -> Logger.debug("[Receipt.Emitter] Stored signed receipt: #{safe_id}.json")
      {:error, reason} -> Logger.warning("[Receipt.Emitter] Failed to store signed receipt: #{inspect(reason)}")
    end
  rescue
    _ -> :ok
  end
end
