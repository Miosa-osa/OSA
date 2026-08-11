defmodule OptimalSystemAgent.System.AtomicFileTest do
  @moduledoc """
  The three properties every hand-rolled `write tmp; rename tmp` in this tree
  got wrong, plus the one it got right (whole-file replacement).
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.System.AtomicFile

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-atomic-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "write/3 basics" do
    test "creates a file that did not exist", %{dir: dir} do
      path = Path.join(dir, "new.txt")
      assert :ok = AtomicFile.write(path, "hello")
      assert File.read!(path) == "hello"
    end

    test "replaces existing content wholesale rather than appending", %{dir: dir} do
      path = Path.join(dir, "x.txt")
      File.write!(path, "a very long previous body")
      assert :ok = AtomicFile.write(path, "short")
      assert File.read!(path) == "short"
    end

    test "creates the parent directory when missing", %{dir: dir} do
      path = Path.join([dir, "deep", "nested", "f.json"])
      assert :ok = AtomicFile.write(path, "{}")
      assert File.read!(path) == "{}"
    end

    test "accepts iodata", %{dir: dir} do
      path = Path.join(dir, "io.txt")
      assert :ok = AtomicFile.write(path, ["a", ["b", "c"], "d"])
      assert File.read!(path) == "abcd"
    end

    test "leaves no temp file behind", %{dir: dir} do
      path = Path.join(dir, "clean.txt")
      assert :ok = AtomicFile.write(path, "body")
      assert File.ls!(dir) == ["clean.txt"]
    end

    test "returns an error tuple instead of raising when the path is unwritable", %{dir: dir} do
      # A directory where a file is expected: the rename cannot succeed.
      path = Path.join(dir, "iam_a_dir")
      File.mkdir_p!(Path.join(path, "child"))
      assert {:error, _} = AtomicFile.write(path, "nope")
      # And still no temp litter from the failed attempt.
      refute Enum.any?(File.ls!(dir), &String.ends_with?(&1, ".tmp"))
    end

    test "write!/3 raises on failure", %{dir: dir} do
      path = Path.join(dir, "d")
      File.mkdir_p!(Path.join(path, "child"))
      assert_raise File.Error, fn -> AtomicFile.write!(path, "nope") end
    end
  end

  describe "symlink resolution" do
    @tag :tmp_dir
    test "writes THROUGH a symlink instead of replacing it", %{dir: dir} do
      # The dotfiles case: ~/.osa/config.toml is a symlink into a git repo.
      real = Path.join(dir, "dotfiles_config.toml")
      link = Path.join(dir, "config.toml")
      File.write!(real, "original = true\n")
      :ok = File.ln_s(real, link)

      assert :ok = AtomicFile.write(link, "updated = true\n")

      # The link must SURVIVE as a link...
      assert {:ok, _} = :file.read_link(link)
      assert File.lstat!(link).type == :symlink
      # ...and the write must have landed on its target.
      assert File.read!(real) == "updated = true\n"
      assert File.read!(link) == "updated = true\n"
    end

    test "follows a multi-hop symlink chain to the real file", %{dir: dir} do
      real = Path.join(dir, "real.txt")
      mid = Path.join(dir, "mid.txt")
      link = Path.join(dir, "link.txt")
      File.write!(real, "v0")
      :ok = File.ln_s(real, mid)
      :ok = File.ln_s(mid, link)

      assert :ok = AtomicFile.write(link, "v1")

      assert File.read!(real) == "v1"
      assert File.lstat!(mid).type == :symlink
      assert File.lstat!(link).type == :symlink
    end

    test "resolves a RELATIVE link target against the link's own directory", %{dir: dir} do
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)
      real = Path.join(sub, "target.txt")
      link = Path.join(sub, "alias.txt")
      File.write!(real, "before")
      # Relative target — resolving it against cwd instead of the link's dir
      # would write to the wrong place entirely.
      :ok = File.ln_s("target.txt", link)

      assert :ok = AtomicFile.write(link, "after")

      assert File.read!(real) == "after"
      assert File.lstat!(link).type == :symlink
    end

    test "a dangling symlink is materialized at the link target, not over the link",
         %{dir: dir} do
      real = Path.join(dir, "missing.txt")
      link = Path.join(dir, "dangling.txt")
      :ok = File.ln_s(real, link)
      refute File.exists?(real)

      assert :ok = AtomicFile.write(link, "created")

      assert File.read!(real) == "created"
      assert File.lstat!(link).type == :symlink
    end

    test "a symlink loop does not hang and still produces a write", %{dir: dir} do
      a = Path.join(dir, "a")
      b = Path.join(dir, "b")
      :ok = File.ln_s(b, a)
      :ok = File.ln_s(a, b)

      # Whatever it resolves to, it must terminate and not raise.
      assert AtomicFile.write(a, "x") in [:ok, {:error, :eloop}, {:error, :eexist}]
    end
  end

  describe "mode preservation" do
    test "preserves the existing file's mode", %{dir: dir} do
      path = Path.join(dir, "creds.env")
      File.write!(path, "OLD=1")
      File.chmod!(path, 0o600)

      assert :ok = AtomicFile.write(path, "NEW=1")

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert File.read!(path) == "NEW=1"
    end

    test "preserves a non-default mode too", %{dir: dir} do
      path = Path.join(dir, "exec.sh")
      File.write!(path, "#!/bin/sh\n")
      File.chmod!(path, 0o750)

      assert :ok = AtomicFile.write(path, "#!/bin/sh\necho hi\n")

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o750
    end

    test "preserves the mode of the symlink's TARGET", %{dir: dir} do
      real = Path.join(dir, "secret_real")
      link = Path.join(dir, "secret_link")
      File.write!(real, "K=1")
      File.chmod!(real, 0o600)
      :ok = File.ln_s(real, link)

      assert :ok = AtomicFile.write(link, "K=2")

      assert Bitwise.band(File.stat!(real).mode, 0o777) == 0o600
    end

    test ":mode option overrides the existing mode", %{dir: dir} do
      path = Path.join(dir, "forced")
      File.write!(path, "x")
      File.chmod!(path, 0o644)

      assert :ok = AtomicFile.write(path, "y", mode: 0o600)

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test ":mode applies to a brand new file", %{dir: dir} do
      path = Path.join(dir, "brand_new")
      assert :ok = AtomicFile.write(path, "k", mode: 0o600)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test ":default_mode applies only when the file does not exist", %{dir: dir} do
      new = Path.join(dir, "fresh")
      assert :ok = AtomicFile.write(new, "a", default_mode: 0o600)
      assert Bitwise.band(File.stat!(new).mode, 0o777) == 0o600

      existing = Path.join(dir, "already")
      File.write!(existing, "a")
      File.chmod!(existing, 0o644)
      assert :ok = AtomicFile.write(existing, "b", default_mode: 0o600)
      assert Bitwise.band(File.stat!(existing).mode, 0o777) == 0o644
    end
  end

  describe "resolve_symlink/1" do
    test "returns a plain path unchanged", %{dir: dir} do
      path = Path.join(dir, "plain")
      File.write!(path, "x")
      assert AtomicFile.resolve_symlink(path) == path
    end

    test "returns a nonexistent path unchanged", %{dir: dir} do
      path = Path.join(dir, "nope")
      assert AtomicFile.resolve_symlink(path) == path
    end

    test "resolves to the final target of a chain", %{dir: dir} do
      real = Path.join(dir, "r")
      mid = Path.join(dir, "m")
      link = Path.join(dir, "l")
      File.write!(real, "x")
      :ok = File.ln_s(real, mid)
      :ok = File.ln_s(mid, link)
      assert AtomicFile.resolve_symlink(link) == real
    end
  end

  describe "concurrent writers" do
    test "every reader sees a complete file, never a torn one", %{dir: dir} do
      path = Path.join(dir, "hot.json")
      bodies = for i <- 1..20, do: String.duplicate("#{rem(i, 10)}", 50_000)
      File.write!(path, List.first(bodies))

      writers =
        for body <- bodies do
          Task.async(fn -> AtomicFile.write(path, body) end)
        end

      readers =
        for _ <- 1..40 do
          Task.async(fn ->
            Process.sleep(:rand.uniform(5))
            File.read!(path)
          end)
        end

      assert Enum.all?(Task.await_many(writers, 10_000), &(&1 == :ok))

      # A torn write would show up as a body of the wrong length. Every read
      # must be byte-identical to one of the bodies actually written.
      for seen <- Task.await_many(readers, 10_000) do
        assert seen in bodies, "reader observed a torn file of #{byte_size(seen)} bytes"
      end
    end
  end
end
