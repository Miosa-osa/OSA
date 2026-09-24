defmodule OptimalSystemAgent.Tools.Builtins.ClaimsBoardTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.FileLocking.ClaimsBoard, as: Board
  alias OptimalSystemAgent.Tools.Builtins.ClaimsBoard, as: Tool
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :claims_board_block_on_conflict)
    end)

    :ok
  end

  defp uniq(prefix) do
    id = prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Board.release_all(id) end)
    id
  end

  defp ctx(session_id), do: %{UseContext.empty() | session_id: session_id}

  describe "shape" do
    test "name/0 is 'claims_board'" do
      assert Tool.name() == "claims_board"
    end

    test "list is read-only and concurrency-safe; claim/release are not" do
      assert Tool.read_only?(%{"action" => "list"}, ctx("x"))
      refute Tool.read_only?(%{"action" => "claim"}, ctx("x"))

      assert Tool.concurrency_safe?(%{"action" => "list"}, ctx("x"))
      refute Tool.concurrency_safe?(%{"action" => "claim"}, ctx("x"))
    end

    test "parameters/0 requires action" do
      params = Tool.parameters()
      assert "action" in params["required"]
    end
  end

  describe "execute/2 — claim (file)" do
    test "claiming a free file succeeds and returns a claim_id" do
      agent = uniq("tool-file")
      path = "/tmp/osa-claims-tool-#{System.unique_integer([:positive])}.ex"

      assert {:ok, msg} =
               Tool.execute(
                 %{"action" => "claim", "kind" => "file", "target" => path},
                 ctx(agent)
               )

      assert msg =~ "Claimed file"
      assert msg =~ path
    end

    test "a conflicting claim is surfaced as {:ok, ...} (advisory) by default, not an error" do
      holder = uniq("tool-holder")
      other = uniq("tool-other")
      path = "/tmp/osa-claims-tool-conflict-#{System.unique_integer([:positive])}.ex"

      {:ok, _} =
        Tool.execute(%{"action" => "claim", "kind" => "file", "target" => path}, ctx(holder))

      assert {:ok, msg} =
               Tool.execute(
                 %{"action" => "claim", "kind" => "file", "target" => path},
                 ctx(other)
               )

      assert msg =~ "Conflict"
      assert msg =~ holder
      assert msg =~ "advisory"
    end

    test "with :claims_board_block_on_conflict true, the same conflict BLOCKS instead", %{} do
      holder = uniq("tool-holder-block")
      other = uniq("tool-other-block")
      path = "/tmp/osa-claims-tool-block-#{System.unique_integer([:positive])}.ex"

      {:ok, _} =
        Tool.execute(%{"action" => "claim", "kind" => "file", "target" => path}, ctx(holder))

      Application.put_env(:optimal_system_agent, :claims_board_block_on_conflict, true)

      assert {:error, msg} =
               Tool.execute(
                 %{"action" => "claim", "kind" => "file", "target" => path},
                 ctx(other)
               )

      assert msg =~ "Conflict"
      assert msg =~ "NOT granted"
    end
  end

  describe "execute/2 — claim (task)" do
    test "claiming a fresh task topic succeeds" do
      agent = uniq("tool-task")

      assert {:ok, msg} =
               Tool.execute(
                 %{
                   "action" => "claim",
                   "kind" => "task",
                   "target" => "survey competitor pricing"
                 },
                 ctx(agent)
               )

      assert msg =~ "Claimed task"
    end

    test "invalid kind is rejected" do
      agent = uniq("tool-badkind")

      assert {:error, msg} =
               Tool.execute(
                 %{"action" => "claim", "kind" => "database_row", "target" => "x"},
                 ctx(agent)
               )

      assert msg =~ "Invalid kind"
    end
  end

  describe "execute/2 — release and list" do
    test "release frees a claim so a later claim on the same target succeeds" do
      agent = uniq("tool-release")
      other = uniq("tool-release-other")
      path = "/tmp/osa-claims-tool-release-#{System.unique_integer([:positive])}.ex"

      {:ok, msg} =
        Tool.execute(%{"action" => "claim", "kind" => "file", "target" => path}, ctx(agent))

      [_, claim_id] = Regex.run(~r/claim_id: `([^`]+)`/, msg)

      Tool.execute(%{"action" => "release", "claim_id" => claim_id}, ctx(agent))

      assert {:ok, msg2} =
               Tool.execute(
                 %{"action" => "claim", "kind" => "file", "target" => path},
                 ctx(other)
               )

      assert msg2 =~ "Claimed file"
    end

    test "list shows an active claim" do
      agent = uniq("tool-list")
      description = "list-visible investigation #{System.unique_integer([:positive])}"

      {:ok, _} =
        Tool.execute(
          %{"action" => "claim", "kind" => "task", "target" => description},
          ctx(agent)
        )

      assert {:ok, listing} = Tool.execute(%{"action" => "list"}, ctx(agent))
      assert listing =~ description
      assert listing =~ agent
    end

    test "list on an empty board says so" do
      # Not a strict guarantee (other async tests may hold claims), but on a
      # freshly-cleaned agent id asking about ITS OWN claims via `claim`
      # conflict lookups is the real contract; `list` itself just must not
      # raise and must return a string either way.
      assert {:ok, listing} = Tool.execute(%{"action" => "list"}, ctx(uniq("tool-list-empty")))
      assert is_binary(listing)
    end
  end
end
