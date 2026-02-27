defmodule OptimalSystemAgent.Tools.Builtins.FileWriteTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileWrite

  # ---------------------------------------------------------------------------
  # Blocked system paths
  # ---------------------------------------------------------------------------

  describe "blocked system paths" do
    test "writing to /etc/ is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "/etc/evil.conf", "content" => "x"})
      assert msg =~ "Access denied"
    end

    test "writing to /usr/ is blocked" do
      assert {:error, msg} =
               FileWrite.execute(%{"path" => "/usr/local/bin/evil", "content" => "x"})

      assert msg =~ "Access denied"
    end

    test "writing to /bin/ is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "/bin/evil", "content" => "x"})
      assert msg =~ "Access denied"
    end

    test "writing to /sbin/ is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "/sbin/evil", "content" => "x"})
      assert msg =~ "Access denied"
    end

    test "writing to /var/ is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "/var/log/evil", "content" => "x"})
      assert msg =~ "Access denied"
    end

    test "writing to /boot/ is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "/boot/evil", "content" => "x"})
      assert msg =~ "Access denied"
    end
  end

  # ---------------------------------------------------------------------------
  # Blocked dotfiles outside ~/.osa/
  # ---------------------------------------------------------------------------

  describe "blocked dotfiles" do
    test "writing to ~/.bashrc is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "~/.bashrc", "content" => "x"})
      assert msg =~ "Access denied"
    end

    test "writing to ~/.zshrc is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "~/.zshrc", "content" => "x"})
      assert msg =~ "Access denied"
    end

    test "writing to ~/.ssh/config is blocked" do
      assert {:error, msg} = FileWrite.execute(%{"path" => "~/.ssh/config", "content" => "x"})
      assert msg =~ "Access denied"
    end

    test "writing to ~/.config/something is blocked" do
      assert {:error, msg} =
               FileWrite.execute(%{"path" => "~/.config/evil.json", "content" => "x"})

      assert msg =~ "Access denied"
    end
  end

  # ---------------------------------------------------------------------------
  # Allowed paths
  # ---------------------------------------------------------------------------

  describe "allowed paths" do
    test "writing to ~/.osa/ is allowed" do
      path = Path.expand("~/.osa/workspace/test_write_#{:rand.uniform(100_000)}.txt")

      try do
        assert {:ok, msg} = FileWrite.execute(%{"path" => path, "content" => "hello"})
        assert msg =~ "Written to"
        assert File.read!(path) == "hello"
      after
        File.rm(path)
      end
    end

    test "writing to /tmp is allowed" do
      path = "/tmp/osa_test_write_#{:rand.uniform(100_000)}.txt"

      try do
        assert {:ok, _} = FileWrite.execute(%{"path" => path, "content" => "tmp test"})
        assert File.read!(path) == "tmp test"
      after
        File.rm(path)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns file_write" do
      assert FileWrite.name() == "file_write"
    end

    test "parameters returns valid JSON schema" do
      params = FileWrite.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "path")
      assert Map.has_key?(params["properties"], "content")
    end
  end
end
