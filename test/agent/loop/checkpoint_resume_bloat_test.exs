defmodule OptimalSystemAgent.Agent.Loop.CheckpointResumeBloatTest do
  @moduledoc """
  A resumed session comes back the size it was, with its text intact.

  Reported live: a session resumed at 151k input tokens. Its checkpoint held
  363 messages, 153 of them per-step notes (91 advisor recommendations), and
  every non-ASCII character was mojibake two or three layers deep, because the
  file was written with `File.write!(path, json, [:utf8])` and each resume
  wrote the damaged text back out with another layer.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Checkpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-ckpt-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:optimal_system_agent, :checkpoint_dir)
    Application.put_env(:optimal_system_agent, :checkpoint_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:optimal_system_agent, :checkpoint_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :checkpoint_dir)
    end)

    {:ok, sid: "ckpt-#{System.unique_integer([:positive])}"}
  end

  defp state(sid, messages) do
    %{
      session_id: sid,
      messages: messages,
      iteration: 3,
      plan_mode: false,
      turn_count: 2,
      session_cost_usd: 0.0,
      session_input_tokens: 0,
      session_output_tokens: 0,
      session_cache_creation_tokens: 0,
      session_cache_read_tokens: 0,
      max_budget_usd: nil,
      started_at: nil
    }
  end

  # What one `[:utf8]` write did to the text.
  defp one_layer(text), do: :unicode.characters_to_binary(text, :latin1, :utf8)

  test "non-ASCII text survives repeated save and restore unchanged", %{sid: sid} do
    text = "Done — the café's naïve résumé ✓ 你好"

    final =
      Enum.reduce(1..4, text, fn _, current ->
        Checkpoint.checkpoint_state(state(sid, [%{role: "user", content: current}]))
        %{messages: [%{content: restored}]} = Checkpoint.restore_checkpoint(sid)
        restored
      end)

    assert final == text
  end

  test "text damaged by earlier writes is repaired on restore", %{sid: sid} do
    two = one_layer(one_layer("the fix — done"))
    three = one_layer(two)

    path = Checkpoint.checkpoint_path(sid)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "messages" => [
          %{"role" => "assistant", "content" => two},
          %{"role" => "assistant", "content" => three},
          %{"role" => "user", "content" => [%{"type" => "text", "text" => two}]},
          %{"role" => "user", "content" => "plain café"}
        ]
      })
    )

    %{messages: [a, b, c, d]} = Checkpoint.restore_checkpoint(sid)
    assert a.content == "the fix — done"
    assert b.content == "the fix — done"
    assert [%{"text" => "the fix — done"}] = c.content
    assert d.content == "plain café"
  end

  test "a restored session keeps one note of each kind", %{sid: sid} do
    notes =
      Enum.flat_map(1..40, fn n ->
        [
          %{role: "system", content: "[ADVISOR RECOMMENDATION — advice #{n}"},
          %{role: "system", content: "[Output contract — inform] #{n}"},
          %{role: "user", content: "q#{n}"}
        ]
      end)

    Checkpoint.checkpoint_state(state(sid, [%{role: "system", content: "You are OSA."} | notes]))
    %{messages: restored} = Checkpoint.restore_checkpoint(sid)

    assert length(restored) == 1 + 40 + 2
    assert Enum.count(restored, &(&1.content =~ "ADVISOR RECOMMENDATION")) == 1
    assert Enum.any?(restored, &(&1.content == "[ADVISOR RECOMMENDATION — advice 40"))
  end
end
