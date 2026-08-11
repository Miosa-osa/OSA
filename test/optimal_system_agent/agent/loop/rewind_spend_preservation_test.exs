defmodule OptimalSystemAgent.Agent.Loop.RewindSpendPreservationTest do
  @moduledoc """
  A `/rewind` must not zero the money.

  `Checkpoint.restore_conversation/1` rewrites the crash-recovery checkpoint so
  a resume loads the rewound messages. It did so by handing a **five-key map**
  (session_id/messages/iteration/plan_mode/turn_count) to `checkpoint_state/1`,
  which writes the **full** record — so every field absent from that map was
  written as its default: `session_cost_usd` → 0.0, all four token counters →
  0, and `max_budget_usd` → nil (i.e. *uncapped*). `checkpoint_state/1` then
  mirrors those zeros into the durable spend sidecar, making the loss survive a
  restart.

  Net effect, reachable by a normal `/rewind` (scope `:conversation` or
  `:both`) and by `Rewind.unrevert/1`: a $48-of-$50 run resumes at $0 with no
  cap — the exact scenario the sidecar's own moduledoc exists to prevent.

  These tests assert the accounting survives a partial restore, in memory *and*
  on disk, and that the writer itself can no longer be made to write defaults
  over fields a caller did not supply.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.SessionPersistence

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_rewind_spend_#{System.unique_integer([:positive])}")
    crash = Path.join(tmp, "checkpoints")
    rewind = Path.join(tmp, "rewind")
    home = Path.join(tmp, "home")
    Enum.each([crash, rewind, home], &File.mkdir_p!/1)

    prev = %{
      checkpoint_dir: Application.get_env(:optimal_system_agent, :checkpoint_dir),
      rewind_checkpoint_dir: Application.get_env(:optimal_system_agent, :rewind_checkpoint_dir),
      config_dir: Application.get_env(:optimal_system_agent, :config_dir)
    }

    Application.put_env(:optimal_system_agent, :checkpoint_dir, crash)
    Application.put_env(:optimal_system_agent, :rewind_checkpoint_dir, rewind)
    Application.put_env(:optimal_system_agent, :config_dir, home)

    on_exit(fn ->
      Enum.each(prev, fn {k, v} -> restore_env(k, v) end)
      File.rm_rf(tmp)
    end)

    {:ok, session: "rewind_spend_#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # A live loop state that has spent $48.25 of a $50.00 cap.
  defp spent_state(session, messages) do
    %{
      session_id: session,
      messages: messages,
      iteration: 7,
      plan_mode: false,
      turn_count: 3,
      session_cost_usd: 48.25,
      session_input_tokens: 1_200,
      session_output_tokens: 800,
      session_cache_creation_tokens: 100,
      session_cache_read_tokens: 50,
      max_budget_usd: 50.0,
      started_at: ~U[2026-08-01 00:00:00Z]
    }
  end

  defp msg(role, content), do: %{role: role, content: content}

  describe "/rewind with conversation scope" do
    test "keeps the accumulated spend and the budget cap on the crash checkpoint",
         %{session: session} do
      early = [msg("user", "one")]
      later = early ++ [msg("assistant", "ok"), msg("user", "two")]

      # A snapshot taken before the second prompt (what /rewind will go back to).
      {:ok, id} =
        Checkpoint.create_rewind_checkpoint(spent_state(session, early),
          label: "before prompt two",
          fs_head: nil
        )

      # ...then the run continues and spends money.
      Checkpoint.checkpoint_state(spent_state(session, later))

      assert %{session_cost_usd: 48.25, max_budget_usd: 50.0} = Checkpoint.restore_checkpoint(session)

      {:ok, result} = Checkpoint.restore_rewind(session, id, :conversation)
      assert %{status: "restored"} = result.conversation

      restored = Checkpoint.restore_checkpoint(session)

      # The conversation really did rewind...
      assert length(restored.messages) == 1

      # ...and the accounting did NOT.
      assert restored.session_cost_usd == 48.25,
             "a /rewind zeroed the running spend — the run now resumes at $0 and blows past its cap"

      assert restored.max_budget_usd == 50.0,
             "a /rewind erased the $50 budget cap — the session resumes UNCAPPED"

      assert restored.session_input_tokens == 1_200
      assert restored.session_output_tokens == 800
      assert restored.session_cache_creation_tokens == 100
      assert restored.session_cache_read_tokens == 50
    end

    test "keeps the accumulated spend in the DURABLE sidecar, not just in the checkpoint",
         %{session: session} do
      early = [msg("user", "one")]

      {:ok, id} =
        Checkpoint.create_rewind_checkpoint(spent_state(session, early), fs_head: nil)

      Checkpoint.checkpoint_state(spent_state(session, early ++ [msg("user", "two")]))
      assert SessionPersistence.load_spend(session).cost_usd == 48.25

      {:ok, _} = Checkpoint.restore_rewind(session, id, :conversation)

      spend = SessionPersistence.load_spend(session)

      assert spend.cost_usd == 48.25,
             "the /rewind mirrored a zeroed spend into the durable sidecar — the loss survives a restart"

      assert spend.input_tokens == 1_200
      assert spend.output_tokens == 800
    end

    test "unrevert (scope :both) also preserves the accounting", %{session: session} do
      early = [msg("user", "one")]

      {:ok, id} = Checkpoint.create_rewind_checkpoint(spent_state(session, early), fs_head: nil)
      Checkpoint.checkpoint_state(spent_state(session, early ++ [msg("user", "two")]))

      {:ok, _} = Checkpoint.restore_rewind(session, id, :both)

      restored = Checkpoint.restore_checkpoint(session)
      assert restored.session_cost_usd == 48.25
      assert restored.max_budget_usd == 50.0
    end
  end

  describe "the full-record writer" do
    test "a partial map never writes defaults over fields it did not supply",
         %{session: session} do
      Checkpoint.checkpoint_state(spent_state(session, [msg("user", "one")]))

      # The general defect: any caller handing a partial map to the full-record
      # writer silently reset every field it omitted.
      Checkpoint.checkpoint_state(%{
        session_id: session,
        messages: [msg("user", "rewritten")],
        iteration: 0,
        plan_mode: false,
        turn_count: 0
      })

      restored = Checkpoint.restore_checkpoint(session)

      assert length(restored.messages) == 1
      assert hd(restored.messages)[:content] == "rewritten"
      assert restored.session_cost_usd == 48.25
      assert restored.max_budget_usd == 50.0
      assert restored.session_input_tokens == 1_200
    end

    test "update_checkpoint/1 is the explicit partial-update path", %{session: session} do
      Checkpoint.checkpoint_state(spent_state(session, [msg("user", "one")]))

      :ok =
        Checkpoint.update_checkpoint(%{
          session_id: session,
          messages: [],
          iteration: 0,
          turn_count: 0
        })

      restored = Checkpoint.restore_checkpoint(session)
      assert restored.messages == []
      assert restored.turn_count == 0
      assert restored.session_cost_usd == 48.25
      assert restored.max_budget_usd == 50.0
    end

    test "a full record still writes exactly what it was given", %{session: session} do
      Checkpoint.checkpoint_state(spent_state(session, [msg("user", "one")]))

      # A genuinely cheaper turn must be able to LOWER a counter — the merge
      # must not become a one-way ratchet on the record's own writer.
      full =
        spent_state(session, [msg("user", "one")])
        |> Map.merge(%{session_cost_usd: 0.5, session_input_tokens: 3, max_budget_usd: nil})

      Checkpoint.checkpoint_state(full)

      restored = Checkpoint.restore_checkpoint(session)
      assert restored.session_cost_usd == 0.5
      assert restored.session_input_tokens == 3
      assert restored.max_budget_usd == nil
    end
  end
end
