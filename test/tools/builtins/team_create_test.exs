defmodule OptimalSystemAgent.Tools.Builtins.TeamCreateTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.TeamCreate.{Constants, Handler, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── Constants ─────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name is 'team_create'" do
      assert Constants.tool_name() == "team_create"
    end

    test "max_name_length is positive" do
      assert Constants.max_name_length() > 0
    end

    test "max_members is positive" do
      assert Constants.max_members() > 0
    end
  end

  # ── Handler.validate/2 ───────────────────────────────────────────────

  describe "validate/2 — happy paths" do
    test "accepts minimal valid input", %{ctx: ctx} do
      input = %{"name" => "alpha", "members" => ["backend"]}
      # With empty registry, unknown roles are allowed through
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "accepts input with optional goal", %{ctx: ctx} do
      input = %{"name" => "my-team", "members" => ["backend"], "goal" => "build API"}
      assert {:ok, _} = Handler.validate(input, ctx)
    end

    test "accepts input with budget_usd", %{ctx: ctx} do
      input = %{"name" => "squad", "members" => ["backend", "frontend"], "budget_usd" => 5.0}
      assert {:ok, _} = Handler.validate(input, ctx)
    end

    test "accepts multiple known members", %{ctx: ctx} do
      input = %{"name" => "big-team", "members" => ["backend", "frontend", "devops"]}
      assert {:ok, _} = Handler.validate(input, ctx)
    end
  end

  describe "validate/2 — missing parameters" do
    test "rejects missing name", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"members" => ["backend"]}, ctx)
      assert msg =~ "name"
    end

    test "rejects missing members", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"name" => "alpha"}, ctx)
      assert msg =~ "members"
    end

    test "rejects empty map", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx)
      assert msg =~ "name" or msg =~ "members"
    end
  end

  describe "validate/2 — name constraints" do
    test "rejects empty name", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"name" => "", "members" => ["x"]}, ctx)
      assert msg =~ "empty"
    end

    test "rejects name over max_name_length", %{ctx: ctx} do
      long_name = String.duplicate("a", Constants.max_name_length() + 1)

      assert {:error, msg, -32_602} =
               Handler.validate(%{"name" => long_name, "members" => ["x"]}, ctx)

      assert msg =~ "characters"
    end

    test "accepts name exactly at max_name_length", %{ctx: ctx} do
      exact_name = String.duplicate("a", Constants.max_name_length())
      # Use a real role from the agents registry — "x" would fail the
      # member-validation step before we get to the name-length check.
      input = %{"name" => exact_name, "members" => ["explorer"]}
      assert {:ok, _} = Handler.validate(input, ctx)
    end
  end

  describe "validate/2 — members constraints" do
    test "rejects empty members list", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"name" => "t", "members" => []}, ctx)
      assert msg =~ "non-empty"
    end

    test "rejects non-binary member", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"name" => "t", "members" => ["ok", 42]}, ctx)

      assert msg =~ "string"
    end

    test "rejects members list exceeding max_members", %{ctx: ctx} do
      too_many = Enum.map(1..(Constants.max_members() + 1), &"role-#{&1}")

      assert {:error, msg, -32_602} =
               Handler.validate(%{"name" => "t", "members" => too_many}, ctx)

      assert msg =~ "maximum"
    end

    test "rejects non-list members", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"name" => "t", "members" => "backend"}, ctx)

      assert msg =~ "list"
    end
  end

  describe "validate/2 — role deduplication (populated registry)" do
    test "rejects duplicate roles when registry is populated" do
      # Seed persistent_term with a known role so the registry path is exercised
      key = {OptimalSystemAgent.Agents.Registry, :definitions}
      :persistent_term.put(key, %{"backend" => %{name: "backend"}})

      ctx = UseContext.empty()
      input = %{"name" => "t", "members" => ["backend", "backend"]}
      result = Handler.validate(input, ctx)
      assert {:error, msg, -32_602} = result
      assert msg =~ "Duplicate"
    after
      :persistent_term.erase({OptimalSystemAgent.Agents.Registry, :definitions})
    end

    test "rejects unknown roles when registry is populated" do
      key = {OptimalSystemAgent.Agents.Registry, :definitions}
      :persistent_term.put(key, %{"backend" => %{name: "backend"}})

      ctx = UseContext.empty()
      input = %{"name" => "t", "members" => ["backend", "ghost-role"]}
      result = Handler.validate(input, ctx)
      assert {:error, msg, -32_602} = result
      assert msg =~ "ghost-role"
    after
      :persistent_term.erase({OptimalSystemAgent.Agents.Registry, :definitions})
    end
  end

  # ── Handler.check_permissions/2 ──────────────────────────────────────

  describe "check_permissions/2" do
    test "denies in read_only tier" do
      ctx = %UseContext{UseContext.empty() | permission_tier: :read_only}

      assert {:deny, reason} =
               Handler.check_permissions(%{"name" => "t", "members" => ["x"]}, ctx)

      assert reason =~ "read-only"
    end

    test "allows in full tier" do
      ctx = %UseContext{UseContext.empty() | permission_tier: :full}
      input = %{"name" => "t", "members" => ["x"]}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end

    test "allows in subagent tier" do
      ctx = %UseContext{UseContext.empty() | permission_tier: :subagent}
      input = %{"name" => "t", "members" => ["x"]}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end

    test "denies when permission_tier is :read_only (UseContext.empty() default)" do
      # UseContext.empty() sets permission_tier: :read_only — team_create is denied
      ctx = UseContext.empty()
      assert {:deny, _} = Handler.check_permissions(%{"name" => "t", "members" => ["x"]}, ctx)
    end
  end

  # ── Tool module callbacks ─────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name and identity" do
      assert Tool.name() == "team_create"
      assert "create_team" in Tool.aliases()
      assert "spawn_team" in Tool.aliases()
      assert Tool.search_hint() != ""
    end

    test "loading semantics" do
      assert Tool.should_defer?()
      refute Tool.always_load?()
    end

    test "execution semantics" do
      ctx = UseContext.empty()
      refute Tool.concurrency_safe?(%{}, ctx)
      refute Tool.read_only?(%{}, ctx)
      refute Tool.destructive?(%{}, ctx)
      assert Tool.open_world?(%{}, ctx)
    end

    test "parameters schema has required fields" do
      params = Tool.parameters()
      assert params["type"] == "object"
      assert "name" in params["required"]
      assert "members" in params["required"]
      assert Map.has_key?(params["properties"], "name")
      assert Map.has_key?(params["properties"], "members")
      assert Map.has_key?(params["properties"], "goal")
    end

    test "delegates pipeline to Handler" do
      ctx = UseContext.empty()
      bad_input = %{}
      assert {:error, _, -32_602} = Tool.validate_input(bad_input, ctx)
    end
  end

  # ── UI renders ───────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use stage" do
      result = UI.render(:tool_use, %{"name" => "squad", "members" => ["a", "b"]}, [])
      assert result.kind == "team_create"
      assert result.name == "squad"
      assert result.member_count == 2
    end

    test "tool_result stage" do
      result = UI.render(:tool_result, "Team created. team_id=abc", [])
      assert result.kind == "team_create_result"
      assert result.message =~ "abc"
    end

    test "error stage" do
      result = UI.render(:error, "something broke", [])
      assert result.kind == "team_create_error"
    end

    test "rejected stage" do
      result = UI.render(:rejected, "not allowed", [])
      assert result.kind == "team_create_rejected"
    end

    test "unknown stage returns nil" do
      assert UI.render(:progress, %{}, []) == nil
    end
  end
end
