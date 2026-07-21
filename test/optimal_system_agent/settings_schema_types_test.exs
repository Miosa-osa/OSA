defmodule OptimalSystemAgent.SettingsSchemaTypesTest do
  # Covers the enum + integer-constraint validation and the CC-parity keys.
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Settings.Schema

  test "clean known keys produce no issues" do
    assert Schema.validate(%{
             "effort_level" => "high",
             "permission_mode" => "overdrive",
             "http_port" => 9089,
             "context_refs_budget" => 30_000,
             "disableAllHooks" => true,
             "cleanupPeriodDays" => 0,
             "includeCoAuthoredBy" => false
           }) == []
  end

  test "enum rejects an out-of-set string with a fix tip" do
    assert [%{key: "effort_level", severity: :error, message: msg, tip: tip}] =
             Schema.validate(%{"effort_level" => "banana"})

    assert msg =~ ~s(one of "fast", "medium", "high")
    assert tip =~ "fast"
  end

  test "pos_integer rejects a fractional/zero port" do
    assert [%{key: "http_port"}] = Schema.validate(%{"http_port" => 0})
    assert [%{key: "http_port"}] = Schema.validate(%{"http_port" => 80.5})
  end

  test "non_neg_integer rejects a stringified number (CC z.int parity)" do
    assert [%{key: "cleanupPeriodDays", message: msg}] =
             Schema.validate(%{"cleanupPeriodDays" => "30"})

    assert msg =~ "whole number"
  end

  test "unknown keys stay open-world (not flagged)" do
    assert Schema.validate(%{"someFutureKey" => 123}) == []
  end
end
