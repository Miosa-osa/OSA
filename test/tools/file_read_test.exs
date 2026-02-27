defmodule OptimalSystemAgent.Tools.Builtins.FileReadTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileRead

  # ---------------------------------------------------------------------------
  # Blocked sensitive paths
  # ---------------------------------------------------------------------------

  describe "blocked sensitive paths" do
    test "reading /etc/shadow is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "/etc/shadow"})
      assert msg =~ "Access denied"
    end

    test "reading /etc/passwd is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "/etc/passwd"})
      assert msg =~ "Access denied"
    end

    test "reading ~/.ssh/id_rsa is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "~/.ssh/id_rsa"})
      assert msg =~ "Access denied"
    end

    test "reading ~/.ssh/id_ed25519 is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "~/.ssh/id_ed25519"})
      assert msg =~ "Access denied"
    end

    test "reading ~/.ssh/id_ecdsa is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "~/.ssh/id_ecdsa"})
      assert msg =~ "Access denied"
    end
  end

  # ---------------------------------------------------------------------------
  # Allowed paths
  # ---------------------------------------------------------------------------

  describe "allowed paths" do
    test "reading a normal file works" do
      path = "/tmp/osa_test_read_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "test content")
        assert {:ok, "test content"} = FileRead.execute(%{"path" => path})
      after
        File.rm(path)
      end
    end

    test "reading a nonexistent file returns error" do
      assert {:error, msg} = FileRead.execute(%{"path" => "/tmp/definitely_does_not_exist_12345"})
      assert msg =~ "Error reading file"
    end

    test "reading ~/.ssh/config is allowed (not a private key)" do
      # We just test it doesn't get the "Access denied" error.
      # It may fail with file-not-found which is fine.
      result = FileRead.execute(%{"path" => "~/.ssh/config"})

      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Access denied"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns file_read" do
      assert FileRead.name() == "file_read"
    end

    test "parameters returns valid JSON schema" do
      params = FileRead.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "path")
    end
  end
end
