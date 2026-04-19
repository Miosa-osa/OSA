defmodule OptimalSystemAgent.OpenComputers.Session.FingerprintTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Session.Fingerprint

  defp tmp_path do
    Path.join(System.tmp_dir!(), "osa_fp_test_#{System.unique_integer([:positive])}.ed25519")
  end

  describe "load_or_generate/1" do
    test "generates a 32-byte binary when file does not exist" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      result = Fingerprint.load_or_generate(path)
      assert is_binary(result)
      assert byte_size(result) == 32
    end

    test "generates and writes file to disk" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      Fingerprint.load_or_generate(path)
      assert File.exists?(path)
    end

    test "file has 0600 permissions after generation" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      Fingerprint.load_or_generate(path)
      {:ok, %{mode: mode}} = File.stat(path)
      # 0o100600 = regular file with 0600 permissions
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "round-trip: generated key can be loaded back" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      first = Fingerprint.load_or_generate(path)
      second = Fingerprint.load_or_generate(path)
      assert first == second
    end

    test "creates parent directories when they don't exist" do
      dir = Path.join(System.tmp_dir!(), "osa_fp_dir_#{System.unique_integer([:positive])}")
      path = Path.join(dir, "subdir/fingerprint.ed25519")
      on_exit(fn -> File.rm_rf(dir) end)

      Fingerprint.load_or_generate(path)
      assert File.exists?(path)
    end

    test "returns 32-byte fallback when file is unreadable" do
      # Write a file then make it unreadable
      path = tmp_path()
      File.write!(path, :crypto.strong_rand_bytes(32), [:binary])
      File.chmod!(path, 0o000)

      on_exit(fn ->
        File.chmod(path, 0o600)
        File.rm(path)
      end)

      result = Fingerprint.load_or_generate(path)
      assert is_binary(result)
      assert byte_size(result) == 32
    end
  end
end
