defmodule OptimalSystemAgent.Speculative.WorkProduct do
  @moduledoc """
  Speculative work container — isolates work-in-progress from real state.

  All artifacts produced during speculative execution are tracked here:
  files, generated messages, and decisions. Nothing in a WorkProduct is
  real until `promote/1` is called. Calling `discard/1` cleans up all
  artifacts with no side effects on real state.

  ## File isolation strategy

  Files are written to a temporary directory `~/.osa/speculative/{spec_id}/`.
  On promote, each entry in `:files_created` and `:files_modified` is
  copied to its target path. On discard the entire temp directory is removed.

  Messages and decisions are in-memory only — they are either emitted
  (promote) or dropped (discard).

  ## Usage

      wp = WorkProduct.new(speculative_id)
      wp = WorkProduct.add_file(wp, "/real/path/foo.ex", content)
      wp = WorkProduct.add_message(wp, %{to: "agent_123", body: "..."})
      wp = WorkProduct.add_decision(wp, "Use approach A because...")

      # If assumptions hold:
      {:ok, promoted_wp} = WorkProduct.promote(wp)

      # If assumptions broke:
      :ok = WorkProduct.discard(wp)
  """

  require Logger

  @speculative_base_dir "~/.osa/speculative"

  @enforce_keys [:id, :temp_dir]
  defstruct id: nil,
            temp_dir: nil,
            files_created: [],
            files_modified: [],
            messages_generated: [],
            decisions_made: [],
            status: :pending

  @type status :: :pending | :promoted | :discarded

  @type file_entry :: %{
          target_path: String.t(),
          temp_path: String.t(),
          content: String.t()
        }

  @type message_entry :: %{
          to: String.t(),
          body: String.t(),
          metadata: map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          temp_dir: String.t(),
          files_created: [file_entry()],
          files_modified: [file_entry()],
          messages_generated: [message_entry()],
          decisions_made: [String.t()],
          status: status()
        }

  # ── Construction ──────────────────────────────────────────────────────────

  @doc "Create a new empty WorkProduct with an isolated temp directory."
  @spec new(String.t()) :: t()
  def new(speculative_id) do
    temp_dir = Path.expand(Path.join(@speculative_base_dir, speculative_id))
    File.mkdir_p!(temp_dir)

    %__MODULE__{id: speculative_id, temp_dir: temp_dir}
  end

  # ── Accumulation ──────────────────────────────────────────────────────────

  @doc """
  Stage a new file to be created at `target_path`.

  Content is written to the temp directory immediately.
  The real `target_path` is only touched on `promote/1`.
  """
  @spec add_file_create(t(), String.t(), String.t()) :: t()
  def add_file_create(%__MODULE__{status: :pending} = wp, target_path, content) do
    temp_path = temp_path_for(wp, target_path)
    File.mkdir_p!(Path.dirname(temp_path))
    File.write!(temp_path, content)

    entry = %{target_path: target_path, temp_path: temp_path, content: content}
    %{wp | files_created: [entry | wp.files_created]}
  rescue
    e ->
      Logger.warning("[WorkProduct] Failed to stage file create #{target_path}: #{Exception.message(e)}")
      wp
  end

  @doc """
  Stage a modification to an existing file at `target_path`.

  The modified content is written to the temp directory. The real file is
  only updated on `promote/1`.
  """
  @spec add_file_modify(t(), String.t(), String.t()) :: t()
  def add_file_modify(%__MODULE__{status: :pending} = wp, target_path, content) do
    temp_path = temp_path_for(wp, target_path)
    File.mkdir_p!(Path.dirname(temp_path))
    File.write!(temp_path, content)

    entry = %{target_path: target_path, temp_path: temp_path, content: content}
    %{wp | files_modified: [entry | wp.files_modified]}
  rescue
    e ->
      Logger.warning("[WorkProduct] Failed to stage file modify #{target_path}: #{Exception.message(e)}")
      wp
  end

  @doc "Record a message generated during speculative execution."
  @spec add_message(t(), map()) :: t()
  def add_message(%__MODULE__{status: :pending} = wp, message) when is_map(message) do
    entry = %{
      to: Map.get(message, :to, Map.get(message, "to", "")),
      body: Map.get(message, :body, Map.get(message, "body", "")),
      metadata: Map.get(message, :metadata, Map.get(message, "metadata", %{}))
    }

    %{wp | messages_generated: [entry | wp.messages_generated]}
  end

  @doc "Record a decision made during speculative execution."
  @spec add_decision(t(), String.t()) :: t()
  def add_decision(%__MODULE__{status: :pending} = wp, decision) when is_binary(decision) do
    %{wp | decisions_made: [decision | wp.decisions_made]}
  end

  # ── Finalization ──────────────────────────────────────────────────────────

  @doc """
  Promote speculative work to real state.

  - Copies staged files from temp dir to their real target paths
  - Returns `{:ok, promoted_wp}` with a summary of what was applied
  - Messages and decisions are returned but NOT automatically emitted —
    the caller is responsible for dispatching them

  Returns `{:error, reason}` if any file copy fails.
  """
  @spec promote(t()) :: {:ok, t()} | {:error, String.t()}
  def promote(%__MODULE__{status: :pending} = wp) do
    with :ok <- copy_files(wp.files_created),
         :ok <- copy_files(wp.files_modified) do
      cleanup_temp_dir(wp.temp_dir)
      {:ok, %{wp | status: :promoted}}
    else
      {:error, reason} ->
        Logger.warning("[WorkProduct] Promotion failed for #{wp.id}: #{reason}")
        {:error, reason}
    end
  end

  def promote(%__MODULE__{status: status}), do: {:error, "Cannot promote — status is #{status}"}

  @doc """
  Discard all speculative artifacts.

  Removes the temp directory. No real files are touched.
  Messages and decisions are dropped silently.
  Always returns `:ok`.
  """
  @spec discard(t()) :: :ok
  def discard(%__MODULE__{} = wp) do
    cleanup_temp_dir(wp.temp_dir)
    Logger.info("[WorkProduct] Discarded speculative work #{wp.id} — #{wp.temp_dir} removed")
    :ok
  end

  # ── Queries ────────────────────────────────────────────────────────────────

  @doc "Summary of what this work product contains."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = wp) do
    %{
      id: wp.id,
      status: wp.status,
      files_created: length(wp.files_created),
      files_modified: length(wp.files_modified),
      messages_generated: length(wp.messages_generated),
      decisions_made: length(wp.decisions_made),
      temp_dir: wp.temp_dir
    }
  end

  @doc "True if the work product has any staged artifacts."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = wp) do
    wp.files_created == [] and
      wp.files_modified == [] and
      wp.messages_generated == [] and
      wp.decisions_made == []
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp temp_path_for(wp, target_path) do
    # Mirror the target path structure under temp_dir, stripping the leading /
    relative = String.trim_leading(target_path, "/")
    Path.join(wp.temp_dir, relative)
  end

  defp copy_files(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case File.mkdir_p(Path.dirname(entry.target_path)) do
        :ok ->
          case File.copy(entry.temp_path, entry.target_path) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "Failed to copy #{entry.target_path}: #{inspect(reason)}"}}
          end

        {:error, reason} ->
          {:halt, {:error, "Failed to create dir for #{entry.target_path}: #{inspect(reason)}"}}
      end
    end)
  end

  defp cleanup_temp_dir(temp_dir) do
    File.rm_rf!(temp_dir)
  rescue
    e ->
      Logger.warning("[WorkProduct] Failed to remove temp dir #{temp_dir}: #{Exception.message(e)}")
  end
end
