defmodule OptimalSystemAgent.Agent.Safety.PathPolicyTest do
  @moduledoc """
  The shared sensitive-path / blocked-write policy.

  Each test here fails against the pre-fix tree, where the blocklist was
  copy-pasted into six constants modules plus two tool modules and matched with
  `String.contains?`.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Tools.Builtins.Diff

  @home Path.expand("~")

  describe "credential leak — subscriptions.json (finding 1)" do
    # Pre-fix: only FileRead's list named subscriptions.json. `diff` carried its
    # own copy that did not, so this path was readable through it.
    test "the subscription token store is sensitive" do
      assert PathPolicy.sensitive?(Path.join(@home, ".osa/subscriptions.json"))
    end

    test "diff refuses to render the subscription token store" do
      # A REAL exfiltration attempt: the file exists and sits under an allowed
      # read root, so pre-fix `diff` passed its own (drifted) blocklist, ran
      # `diff -u`, and returned the bearer token in the tool observation.
      dir = Path.join(System.tmp_dir!(), "osa_leak_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, ".osa"))
      store = Path.join(dir, ".osa/subscriptions.json")
      File.write!(store, ~s({"provider":{"access_token":"SECRET-TOKEN-DO-NOT-LEAK"}}))
      empty = Path.join(dir, "empty.json")
      File.write!(empty, "{}")

      try do
        assert {:error, message} = Diff.execute(%{"file_a" => store, "file_b" => empty})
        assert message =~ "Access denied"
        refute message =~ "SECRET-TOKEN"

        # ...and not through the other argument either.
        assert {:error, reversed} = Diff.execute(%{"file_a" => empty, "file_b" => store})
        assert reversed =~ "Access denied"
        refute reversed =~ "SECRET-TOKEN"
      after
        File.rm_rf!(dir)
      end
    end

    test "diff still works on ordinary files" do
      dir = Path.join(System.tmp_dir!(), "osa_diffok_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      a = Path.join(dir, "a.txt")
      b = Path.join(dir, "b.txt")
      File.write!(a, "one\n")
      File.write!(b, "two\n")

      try do
        assert {:ok, output} = Diff.execute(%{"file_a" => a, "file_b" => b})
        assert output =~ "one"
        assert output =~ "two"
      after
        File.rm_rf!(dir)
      end
    end

    test "every tool's sensitive list is the same list" do
      shared = PathPolicy.sensitive_patterns()

      for mod <- [
            OptimalSystemAgent.Tools.Builtins.FileEdit.Constants,
            OptimalSystemAgent.Tools.Builtins.DirList.Constants,
            OptimalSystemAgent.Tools.Builtins.NotebookEdit.Constants
          ] do
        assert mod.sensitive_paths() == shared,
               "#{inspect(mod)} still carries its own sensitive-path list"
      end
    end

    test "every tool's blocked-write list is the same list" do
      shared = PathPolicy.blocked_write_patterns()

      for mod <- [
            OptimalSystemAgent.Tools.Builtins.FileEdit.Constants,
            OptimalSystemAgent.Tools.Builtins.FileWrite.Constants,
            OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Constants,
            OptimalSystemAgent.Tools.Builtins.NotebookEdit.Constants
          ] do
        assert mod.blocked_write_paths() == shared,
               "#{inspect(mod)} still carries its own blocked-write list"
      end
    end
  end

  describe "structural matching, not substring (finding 1)" do
    test "a project directory named var/ is not the system /var" do
      # Pre-fix: String.contains?(path, "/var/") blocked every Symfony/Laravel
      # project, because ~/projects/shop/var/cache contains "/var/".
      refute PathPolicy.blocked_write?(Path.join(@home, "projects/shop/var/cache/x.php"))
    end

    test "a project directory named bin/ or usr/ is not the system one" do
      refute PathPolicy.blocked_write?(Path.join(@home, "projects/app/bin/run.sh"))
      refute PathPolicy.blocked_write?(Path.join(@home, "projects/app/usr/share/x"))
    end

    test "the real system directories are still blocked" do
      assert PathPolicy.blocked_write?("/var/log/syslog")
      assert PathPolicy.blocked_write?("/usr/bin/env")
      assert PathPolicy.blocked_write?("/etc/passwd")
      assert PathPolicy.blocked_write?("/boot/vmlinuz")
    end

    test ".envrc and .env.example are not credential stores" do
      # Pre-fix: String.contains?(path, ".env") matched both.
      refute PathPolicy.sensitive?(Path.join(@home, "projects/app/.envrc"))
      refute PathPolicy.sensitive?(Path.join(@home, "projects/app/docs/.env.example"))
      refute PathPolicy.blocked_write?(Path.join(@home, "projects/app/.envrc"))
    end

    test ".env and per-environment variants still are" do
      assert PathPolicy.sensitive?(Path.join(@home, "projects/app/.env"))
      assert PathPolicy.sensitive?(Path.join(@home, "projects/app/.env.production"))
    end

    test "a directory whose name merely contains a secret name does not match" do
      refute PathPolicy.sensitive?(Path.join(@home, "projects/my.netrc.docs/readme.md"))
    end
  end

  describe ".git is not writable (finding 2)" do
    # Writing .git/config sets core.hooksPath, which is arbitrary code execution
    # on the user's next git command. The dotfile guard never covered this: it
    # inspects only the first component under $HOME.
    test "a git control directory inside an allowed project is blocked" do
      assert PathPolicy.blocked_write?(Path.join(@home, "projects/anything/.git/config"))
      assert PathPolicy.blocked_write?(Path.join(@home, "projects/anything/.git/hooks/pre-commit"))
    end

    test "an ordinary file in the same project is not blocked" do
      refute PathPolicy.blocked_write?(Path.join(@home, "projects/anything/lib/app.ex"))
    end
  end

  describe "check_write canonicalises before deciding (finding 2)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "osa_policy_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "a symlink chain to /etc is refused", %{dir: dir} do
      # A -> B -> /etc. A single readlink(2) validates B and lets the kernel
      # follow the rest; PathCanon walks the whole chain.
      b = Path.join(dir, "b")
      a = Path.join(dir, "a")
      File.ln_s!("/etc", b)
      File.ln_s!(b, a)

      assert {:deny, _} = PathPolicy.check_write(Path.join(a, "passwd"))
    end

    test "an intermediate directory symlink is refused", %{dir: dir} do
      # /allowed/dirlink/target — the leaf is not a link, so a leaf-only
      # readlink saw nothing to resolve and approved the path.
      link = Path.join(dir, "dirlink")
      File.ln_s!("/etc", link)

      assert {:deny, _} = PathPolicy.check_write(Path.join(link, "shadow"))
    end

    test "a relative symlink target resolves against the link's own directory", %{dir: dir} do
      # Pre-fix this became "/" <> target, a fabricated path unrelated to the
      # real target. Here the real target is inside the allowed tmp root, so a
      # correct resolution ALLOWS it; a fabricated "/secrets" would not exist
      # under an allowed root and would be denied.
      File.mkdir_p!(Path.join(dir, "real"))
      File.write!(Path.join(dir, "real/file.txt"), "x")
      File.ln_s!("real", Path.join(dir, "link"))

      assert :ok = PathPolicy.check_write(Path.join(dir, "link/file.txt"))
      assert PathPolicy.canonical(Path.join(dir, "link/file.txt")) =~ "/real/file.txt"
    end

    test "an ordinary file under an allowed root is permitted", %{dir: dir} do
      assert :ok = PathPolicy.check_write(Path.join(dir, "notes.txt"))
    end

    test "a dotfile directly under $HOME is refused" do
      assert {:deny, message} = PathPolicy.check_write(Path.join(@home, ".zshrc"))
      assert message =~ "dotfile"
    end

    test "files under ~/.osa are still writable" do
      assert :ok = PathPolicy.check_write(Path.join(@home, ".osa/workspace/scratch.txt"))
    end
  end
end
