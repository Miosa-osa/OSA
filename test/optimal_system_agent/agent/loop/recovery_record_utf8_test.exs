defmodule OptimalSystemAgent.Agent.Loop.RecoveryRecordUtf8Test do
  @moduledoc """
  Crash-recovery records must not silently lose their tail.

  `DurableLog` and `Loop.Checkpoint` both coerced content to valid UTF-8 with

      case :unicode.characters_to_binary(binary, :utf8) do
        {:error, valid, _} -> valid
        {:incomplete, valid, _} -> valid
        ...

  Both of those clauses DISCARD everything after the offending byte, with no
  marker, no length signal and no log. `:incomplete` is the likely one in
  practice — a chunk boundary landing mid-sequence — so the usual loss was a
  record's tail, not a stray byte.

  These are the records consulted after a crash: a durable step's result is
  replayed to the model INSTEAD of re-running the tool, and a checkpoint's
  messages are restored as the conversation. A silently shortened record is
  indistinguishable from a complete one. `ShellExecute.Handler` already had
  the right discipline — replace bad bytes with U+FFFD and keep the length.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.DurableLog

  @tail "THE-TAIL-THAT-MUST-SURVIVE"

  # A binary whose bad byte sits in the MIDDLE, with meaningful content after
  # it. The old code returned only the part before the bad byte.
  defp truncated_mid, do: <<"head-content ", 0xFF, " ", @tail::binary>>

  # A binary ending in a cut-short multi-byte sequence — the `:incomplete`
  # case, produced by any chunk boundary that lands mid-character.
  defp incomplete_tail, do: <<"head-content ", @tail::binary, 0xE4, 0xB8>>

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-recovery-utf8-#{System.unique_integer([:positive])}")
    ckpt_dir = Path.join(dir, "checkpoints")
    prev_dir = Application.get_env(:optimal_system_agent, :durable_log_dir)
    prev_enabled = Application.get_env(:optimal_system_agent, :durable_execution)
    prev_ckpt = Application.get_env(:optimal_system_agent, :checkpoint_dir)

    Application.put_env(:optimal_system_agent, :durable_log_dir, dir)
    Application.put_env(:optimal_system_agent, :durable_execution, true)
    Application.put_env(:optimal_system_agent, :checkpoint_dir, ckpt_dir)

    on_exit(fn ->
      File.rm_rf(dir)
      restore(:durable_log_dir, prev_dir)
      restore(:durable_execution, prev_enabled)
      restore(:checkpoint_dir, prev_ckpt)
    end)

    {:ok, dir: dir, session: "recovery-utf8-#{System.unique_integer([:positive])}"}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  describe "DurableLog keeps everything after an undecodable byte" do
    test "a bad byte mid-record does not truncate the replayed result", %{session: sid} do
      DurableLog.record(sid, "k1", %{name: "shell_execute"}, %{content: "x"}, truncated_mid())

      %{"k1" => entry} = DurableLog.load(sid)

      assert String.valid?(entry.result)

      assert String.contains?(entry.result, @tail),
             "the recorded result was truncated at the bad byte — a crash-resume would replay " <>
               "a short answer to the model with no indication it is short"

      assert String.contains?(entry.result, "head-content")
    end

    test "an incomplete trailing sequence loses only the partial character", %{session: sid} do
      DurableLog.record(sid, "k2", %{name: "shell_execute"}, %{content: "x"}, incomplete_tail())

      %{"k2" => entry} = DurableLog.load(sid)

      assert String.valid?(entry.result)
      assert String.contains?(entry.result, @tail)
    end

    test "valid content is stored byte-identical", %{session: sid} do
      original = "完全に有効なテキスト — nothing to scrub"
      DurableLog.record(sid, "k3", %{name: "file_read"}, %{content: "x"}, original)

      %{"k3" => entry} = DurableLog.load(sid)
      assert entry.result == original
    end
  end

  describe "Checkpoint keeps everything after an undecodable byte" do
    test "message content is scrubbed, not truncated", %{session: sid} do
      messages = [
        %{role: "user", content: "hello"},
        %{role: "assistant", content: truncated_mid()}
      ]

      assert :ok = Checkpoint.checkpoint_state(%{session_id: sid, messages: messages})

      restored = Checkpoint.restore_checkpoint(sid)
      contents = restored |> messages_of() |> Enum.map(&content_of/1)

      assert Enum.all?(contents, &String.valid?/1)

      assert Enum.any?(contents, &String.contains?(&1, @tail)),
             "the checkpointed message was truncated at the bad byte — the conversation " <>
               "would be restored missing its tail"
    end

    test "an incomplete trailing sequence loses only the partial character", %{session: sid} do
      messages = [%{role: "assistant", content: incomplete_tail()}]

      assert :ok = Checkpoint.checkpoint_state(%{session_id: sid, messages: messages})

      contents =
        sid |> Checkpoint.restore_checkpoint() |> messages_of() |> Enum.map(&content_of/1)

      assert Enum.all?(contents, &String.valid?/1)
      assert Enum.any?(contents, &String.contains?(&1, @tail))
    end
  end

  defp messages_of(nil), do: []
  defp messages_of(%{messages: m}) when is_list(m), do: m
  defp messages_of(%{"messages" => m}) when is_list(m), do: m
  defp messages_of(_), do: []

  defp content_of(%{content: c}) when is_binary(c), do: c
  defp content_of(%{"content" => c}) when is_binary(c), do: c
  defp content_of(_), do: ""
end
