defmodule OptimalSystemAgent.Agent.Tasks.CheckTest do
  @moduledoc """
  `Agent.Tasks.Check` — acceptance checks that the HARNESS runs, not the
  model. Each check type is exercised for real (a real file, a real command)
  rather than mocked, since the whole point of the feature is that the
  verdict comes from something actually happening.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Tasks.Check

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_check_t#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, dir: tmp}
  end

  describe "normalize/1" do
    test "nil in, nil out" do
      assert Check.normalize(nil) == nil
    end

    test "canonicalizes a raw command check to pending" do
      raw = %{"type" => "command", "command" => "true"}

      assert Check.normalize(raw) == %{
               type: "command",
               command: "true",
               path: nil,
               symbol: nil,
               status: "pending",
               last_run_at: nil,
               output: nil
             }
    end

    test "canonicalizes a raw file_exists check" do
      raw = %{"type" => "file_exists", "path" => "lib/foo.ex"}
      assert %{type: "file_exists", path: "lib/foo.ex", status: "pending"} = Check.normalize(raw)
    end

    test "canonicalizes a raw symbol_exists check" do
      raw = %{"type" => "symbol_exists", "path" => "lib/foo.ex", "symbol" => "def bar"}

      assert %{type: "symbol_exists", path: "lib/foo.ex", symbol: "def bar"} =
               Check.normalize(raw)
    end

    test "an unknown type is rejected (nil), not silently accepted" do
      assert Check.normalize(%{"type" => "make_it_so"}) == nil
    end

    test "a check with no type at all is rejected" do
      assert Check.normalize(%{"command" => "true"}) == nil
    end
  end

  describe "run/1 — file_exists" do
    test "passes when the file exists", %{dir: dir} do
      path = Path.join(dir, "present.txt")
      File.write!(path, "hi")

      check = Check.normalize(%{"type" => "file_exists", "path" => path})
      result = Check.run(check)

      assert result.status == "passed"
      assert result.last_run_at != nil
    end

    test "fails when the file does not exist", %{dir: dir} do
      check = Check.normalize(%{"type" => "file_exists", "path" => Path.join(dir, "absent.txt")})
      result = Check.run(check)

      assert result.status == "failed"
      assert result.output =~ "not found"
    end
  end

  describe "run/1 — symbol_exists" do
    test "passes when the substring is present", %{dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "defmodule Foo do\n  def bar, do: :ok\nend\n")

      check = Check.normalize(%{"type" => "symbol_exists", "path" => path, "symbol" => "def bar"})
      assert Check.run(check).status == "passed"
    end

    test "fails when the substring is absent", %{dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "defmodule Foo do\nend\n")

      check = Check.normalize(%{"type" => "symbol_exists", "path" => path, "symbol" => "def bar"})
      assert Check.run(check).status == "failed"
    end

    test "supports a /regex/ symbol", %{dir: dir} do
      path = Path.join(dir, "code.ex")
      File.write!(path, "def handle_call({:foo, _}, _from, state)")

      check =
        Check.normalize(%{
          "type" => "symbol_exists",
          "path" => path,
          "symbol" => "/def handle_call\\(\\{:foo/"
        })

      assert Check.run(check).status == "passed"
    end

    test "fails cleanly when the file cannot be read" do
      check =
        Check.normalize(%{
          "type" => "symbol_exists",
          "path" => "/definitely/does/not/exist.ex",
          "symbol" => "anything"
        })

      result = Check.run(check)
      assert result.status == "failed"
      assert result.output =~ "could not read"
    end
  end

  describe "run/1 — command" do
    test "passes on exit 0" do
      check = Check.normalize(%{"type" => "command", "command" => "true"})
      result = Check.run(check)
      assert result.status == "passed"
    end

    test "fails on nonzero exit, with output captured" do
      check = Check.normalize(%{"type" => "command", "command" => "echo nope && false"})
      result = Check.run(check)

      assert result.status == "failed"
      assert result.output =~ "nope"
    end

    test "times out cleanly rather than hanging" do
      check = Check.normalize(%{"type" => "command", "command" => "sleep 5"})
      result = Check.run(check, timeout_ms: 50)

      assert result.status == "failed"
      assert result.output =~ "timed out"
    end
  end

  describe "run/1 fails closed on garbage input" do
    test "a plain map with no recognized type is returned unchanged" do
      assert Check.run(%{not: :a_check}) == %{not: :a_check}
    end
  end

  describe "serialize/deserialize round-trip" do
    test "nil round-trips to nil" do
      assert Check.serialize(nil) == nil
      assert Check.deserialize(nil) == nil
    end

    test "a run check's verdict survives a serialize/deserialize round-trip" do
      check =
        %{"type" => "command", "command" => "true"}
        |> Check.normalize()
        |> Check.run()

      round_tripped = check |> Check.serialize() |> Check.deserialize()

      assert round_tripped.status == "passed"
      assert round_tripped.type == "command"
      assert round_tripped.command == "true"
      assert %DateTime{} = round_tripped.last_run_at
    end
  end

  describe "describe/1" do
    test "renders each check type as a short human string" do
      assert Check.describe(%{type: "command", command: "mix test"}) == "command: mix test"
      assert Check.describe(%{type: "file_exists", path: "lib/foo.ex"}) =~ "lib/foo.ex"

      assert Check.describe(%{type: "symbol_exists", path: "lib/foo.ex", symbol: "def bar"}) =~
               "def bar"

      assert Check.describe(nil) == nil
    end
  end
end
