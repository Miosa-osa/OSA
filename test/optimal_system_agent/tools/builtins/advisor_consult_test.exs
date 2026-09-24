defmodule OptimalSystemAgent.Tools.Builtins.AdvisorConsultTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.AdvisorConsult

  setup do
    prev = %{
      advisor_enabled: Application.fetch_env(:optimal_system_agent, :advisor_enabled),
      advisor_provider: Application.fetch_env(:optimal_system_agent, :advisor_provider),
      advisor_model: Application.fetch_env(:optimal_system_agent, :advisor_model)
    }

    Application.put_env(:optimal_system_agent, :advisor_enabled, true)
    Application.put_env(:optimal_system_agent, :advisor_provider, :mock)
    Application.put_env(:optimal_system_agent, :advisor_model, "claude-haiku-4-5")
    Application.delete_env(:optimal_system_agent, :mock_provider_final_text)
    Application.delete_env(:optimal_system_agent, :mock_provider_error)

    Process.put(:osa_session_id, "advisor-tool-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      for {key, val} <- prev do
        case val do
          {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end

      Application.delete_env(:optimal_system_agent, :mock_provider_final_text)
      Application.delete_env(:optimal_system_agent, :mock_provider_error)
    end)

    :ok
  end

  test "is registered as a builtin tool" do
    assert Code.ensure_loaded?(AdvisorConsult)
    assert AdvisorConsult.name() == "advisor_consult"
    assert AdvisorConsult.available?()
    assert AdvisorConsult.safety() == :read_only
  end

  test "parameters require a question" do
    assert %{"required" => ["question"]} = AdvisorConsult.parameters()
  end

  test "returns framed advice on success" do
    Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Try approach B.")

    assert {:ok, text} =
             AdvisorConsult.execute(%{
               "question" => "Should I use approach A or B?",
               "context" => "Approach A failed twice with a timeout."
             })

    assert text =~ "ADVISOR RECOMMENDATION"
    assert text =~ "Try approach B."
    assert text =~ "claude-haiku-4-5"
  end

  test "surfaces a clear error when no advisor is configured" do
    Application.delete_env(:optimal_system_agent, :advisor_model)

    assert {:error, message} = AdvisorConsult.execute(%{"question" => "q"})
    assert message =~ "No advisor model is configured"
  end

  test "surfaces a clear error when disabled" do
    Application.put_env(:optimal_system_agent, :advisor_enabled, false)

    assert {:error, message} = AdvisorConsult.execute(%{"question" => "q"})
    assert message =~ "Advisor is disabled"
  end

  test "rejects a missing question argument" do
    assert {:error, message} = AdvisorConsult.execute(%{})
    assert message =~ "question"
  end
end
