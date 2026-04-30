defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Keyframe do
  @moduledoc """
  Keyframe journal — trajectory recording for computer use sessions.

  Inspired by ExeVRM: captures post-action keyframes (screenshots) and
  records a chronological journal for self-verification, replay, and
  doom loop detection.

  Storage: ~/.osa/trajectories/{session_id}/
    journal.jsonl       — action log with timestamps
    keyframe_001.png    — post-action screenshots
  """

  @default_base_dir "~/.osa/trajectories"
  @password_indicators ~w(password senha passwort contraseña mot_de_passe)

  # ── Public API ──────────────────────────────────────────────────────

  @doc "Initialize a journal directory for a session. Returns {:ok, journal_dir}."
  def init_journal(session_id, opts \\ []) do
    base = Keyword.get(opts, :base_dir, Path.expand(@default_base_dir))
    journal_dir = Path.join(base, session_id)
    File.mkdir_p!(journal_dir)

    journal_path = Path.join(journal_dir, "journal.jsonl")
    unless File.exists?(journal_path), do: File.write!(journal_path, "")

    {:ok, journal_dir}
  end

  @doc "Record a journal entry as a JSONL line."
  def record_entry(journal_dir, entry) when is_map(entry) do
    entry = Map.put(entry, :timestamp_ms, System.system_time(:millisecond))
    line = Jason.encode!(entry) <> "\n"
    File.write!(Path.join(journal_dir, "journal.jsonl"), line, [:append])
    :ok
  end

  @doc "Read and parse all journal entries."
  def read_journal(journal_dir) do
    path = Path.join(journal_dir, "journal.jsonl")

    entries =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    {:ok, entries}
  rescue
    _ -> {:ok, []}
  end

  @doc "Save keyframe data to a sequentially named file."
  def save_keyframe(journal_dir, step, data) do
    filename = "keyframe_#{String.pad_leading(Integer.to_string(step), 3, "0")}.png"
    path = Path.join(journal_dir, filename)
    File.write!(path, data)
    {:ok, path}
  end

  @doc """
  Detect doom loop: 3+ consecutive identical keyframe hashes.
  Returns :ok or {:doom_loop, step_count}.
  """
  def detect_doom_loop(journal_dir) do
    case read_journal(journal_dir) do
      {:ok, entries} when length(entries) >= 3 ->
        # Use the explicit keyframe_hash field when present — it captures
        # visual screen state and is the authoritative signal for loop
        # detection.  Fall back to hashing action+result for entries recorded
        # before keyframe capture was wired up.
        last_3_hashes =
          entries
          |> Enum.take(-3)
          |> Enum.map(fn entry ->
            case Map.get(entry, "keyframe_hash") do
              nil ->
                action = Map.get(entry, "action", "")
                result = Map.get(entry, "result", "")
                :crypto.hash(:sha256, "#{action}:#{result}") |> Base.encode16(case: :lower)

              hash ->
                hash
            end
          end)

        if length(Enum.uniq(last_3_hashes)) == 1 do
          {:doom_loop, length(entries)}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Check if keyframe capture should happen based on current element refs.
  Returns false if a password field is detected (security).
  """
  def should_capture?(element_refs) when is_map(element_refs) do
    not Enum.any?(element_refs, fn {_ref, elem} ->
      role = to_string(elem[:role] || elem["role"] || "")
      name = String.downcase(to_string(elem[:name] || elem["name"] || ""))

      role == "password" or
        String.contains?(role, "password") or
        Enum.any?(@password_indicators, &String.contains?(name, &1))
    end)
  end

  def should_capture?(_), do: true

  @doc """
  Clean up old journal directories. Returns {cleaned_count, kept_count}.
  """
  def cleanup_old_journals(base_dir, opts \\ []) do
    max_age = Keyword.get(opts, :max_age_seconds, 86_400)
    now = System.system_time(:second)

    case File.ls(base_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, {0, 0}, fn entry, {c, k} ->
          path = Path.join(base_dir, entry)

          if File.dir?(path) do
            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime_posix}} ->
                if now - mtime_posix > max_age do
                  File.rm_rf!(path)
                  {c + 1, k}
                else
                  {c, k + 1}
                end

              _ ->
                {c, k}
            end
          else
            {c, k}
          end
        end)

      _ ->
        {0, 0}
    end
  end
end
