defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.ReadOnlyTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.ReadOnly
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Tool

  describe "provably_read_only?/1 — positive cases" do
    test "single read-only commands" do
      for cmd <- [
            "ls -la",
            "cat foo.txt",
            "pwd",
            "wc -l file.txt",
            "grep -n foo file.txt",
            "rg --files",
            "fd foo",
            "jq '.foo' file.json",
            "stat file.txt",
            "tree src",
            "head -n 5 file.txt",
            "tail -f file.txt",
            "diff a.txt b.txt",
            "which mix",
            "uname -a",
            "printenv"
          ] do
        assert ReadOnly.provably_read_only?(cmd), "expected read-only: #{cmd}"
      end
    end

    test "read-only pipelines and chains" do
      for cmd <- [
            "cat foo.txt | grep bar | sort | uniq",
            "ls -la && git status",
            "rg --files | wc -l",
            "git diff HEAD~1",
            "git log -3 && git show HEAD",
            "find . -maxdepth 1 -name '*.ex'",
            "head -n 5 file.txt && tail -n 5 file.txt"
          ] do
        assert ReadOnly.provably_read_only?(cmd), "expected read-only: #{cmd}"
      end
    end

    test "git read-only subcommands" do
      for sub <- ~w(status diff log show blame rev-parse ls-files describe) do
        assert ReadOnly.provably_read_only?("git #{sub}"), "expected read-only: git #{sub}"
      end
    end

    test "find without a mutating/exec primary is read-only" do
      assert ReadOnly.provably_read_only?("find . -name '*.ex' -maxdepth 2")
      assert ReadOnly.provably_read_only?("find /tmp -type f")
    end

    test "sed without -i and awk without a redirect-looking program are read-only" do
      assert ReadOnly.provably_read_only?("sed -n '1,5p' file.txt")
      assert ReadOnly.provably_read_only?("awk '{print $1}' file.txt")
    end

    test "bare env (no assignment / no child command) is read-only" do
      assert ReadOnly.provably_read_only?("env")
      assert ReadOnly.provably_read_only?("env -0")
    end

    test "input redirection is read-only (it cannot write)" do
      assert ReadOnly.provably_read_only?("wc -l < file.txt")
    end
  end

  describe "provably_read_only?/1 — negative cases (fail-closed)" do
    test "output redirection of any kind disqualifies the whole command" do
      for cmd <- [
            "echo hi > /etc/motd",
            "cat x > out.txt",
            "cat x >> out.txt",
            "ls -la > /tmp/listing.txt",
            "printf 'x' > out"
          ] do
        refute ReadOnly.provably_read_only?(cmd), "expected NOT read-only: #{cmd}"
      end
    end

    test "a pipe into a non-allowlisted command disqualifies the whole command" do
      for cmd <- [
            "cat foo.txt | tee bar.txt",
            "find . -type f | xargs rm",
            "echo y | rm -i file"
          ] do
        refute ReadOnly.provably_read_only?(cmd), "expected NOT read-only: #{cmd}"
      end
    end

    test "command substitution / parameter expansion is never read-only" do
      for cmd <- [
            "cat $(rm -rf x)",
            "echo `whoami`",
            "echo ${SOME_VAR}",
            "cat $(cat /etc/passwd)"
          ] do
        refute ReadOnly.provably_read_only?(cmd), "expected NOT read-only: #{cmd}"
      end
    end

    test "a chain with ANY non-read-only segment defers, whole line" do
      for cmd <- [
            "ls && rm foo",
            "git status && git commit -m x",
            "git status; git push origin main",
            "ls || rm -rf /",
            "true; rm -rf /tmp/x"
          ] do
        refute ReadOnly.provably_read_only?(cmd), "expected NOT read-only: #{cmd}"
      end
    end

    test "sed -i / --in-place is a write, not a read" do
      assert ReadOnly.provably_read_only?("sed -n '1p' f") == true
      refute ReadOnly.provably_read_only?("sed -i s/a/b/ file")
      refute ReadOnly.provably_read_only?("sed --in-place s/a/b/ file")
      refute ReadOnly.provably_read_only?("sed -i.bak s/a/b/ file")
    end

    test "awk with a redirect-looking program text defers" do
      refute ReadOnly.provably_read_only?(~s(awk '{print $1 > "out.txt"}' file))
    end

    test "find -delete / -exec / -ok disqualify the segment" do
      for cmd <- [
            "find . -delete",
            "find . -exec rm {} \\;",
            "find . -ok rm {} \\;",
            "find . -execdir rm {} \\;"
          ] do
        refute ReadOnly.provably_read_only?(cmd), "expected NOT read-only: #{cmd}"
      end
    end

    test "fdfind with -x/--exec disqualifies the segment" do
      refute ReadOnly.provably_read_only?("fdfind -x rm {}")
      refute ReadOnly.provably_read_only?("fdfind --exec rm {}")
    end

    test "git mutating subcommands are never read-only" do
      for cmd <- [
            "git push origin main",
            "git commit -m x",
            "git reset --hard",
            "git clean -fd",
            "git checkout -- .",
            "git merge foo",
            "git rebase main",
            "git add ."
          ] do
        refute ReadOnly.provably_read_only?(cmd), "expected NOT read-only: #{cmd}"
      end
    end

    test "env with an assignment or a child command is never read-only" do
      refute ReadOnly.provably_read_only?("env FOO=bar ls")
      refute ReadOnly.provably_read_only?("env rm -rf /")
      refute ReadOnly.provably_read_only?("FOO=bar ls")
    end

    test "cd changes shared state and is never read-only, even followed by reads" do
      refute ReadOnly.provably_read_only?("cd /tmp")
      refute ReadOnly.provably_read_only?("cd /tmp && ls")
      refute ReadOnly.provably_read_only?("pushd /tmp && ls")
    end

    test "a bare background operator disqualifies the whole command" do
      refute ReadOnly.provably_read_only?("sleep 5 &")
      refute ReadOnly.provably_read_only?("cat foo.txt &")
      refute ReadOnly.provably_read_only?("cat foo.txt & rm -rf /tmp/x")
    end

    test "known-dangerous heads are never read-only" do
      for cmd <- [
            "rm -rf build",
            "sudo ls",
            "chmod 777 file",
            "chown user file",
            "kill -9 123",
            "mount /dev/sda1 /mnt",
            "systemctl restart nginx",
            "nc -l 1234",
            "shutdown now",
            "mv a b",
            "cp a b",
            "mkdir foo",
            "touch foo",
            "dd if=/dev/zero of=/dev/sda"
          ] do
        refute ReadOnly.provably_read_only?(cmd), "expected NOT read-only: #{cmd}"
      end
    end

    test "an unrecognised binary is never read-only (fail-closed on the unknown)" do
      refute ReadOnly.provably_read_only?("some_custom_deploy_script --prod")
    end

    test "an oversized command is never read-only (CommandVariants bound fails closed)" do
      huge = "cat " <> String.duplicate("a", 25_000)
      refute ReadOnly.provably_read_only?(huge)
    end

    test "empty, blank, or non-binary input is never read-only" do
      refute ReadOnly.provably_read_only?("")
      refute ReadOnly.provably_read_only?(nil)
      refute ReadOnly.provably_read_only?(123)
      refute ReadOnly.provably_read_only?(%{})
    end

    test "a wrapper that hides a write behind an unrecognised head defers" do
      refute ReadOnly.provably_read_only?(~s(bash -c "rm -rf /"))
      refute ReadOnly.provably_read_only?(~s(sh -c "echo hi > /etc/motd"))
    end
  end

  describe "ShellExecute.Tool.concurrency_safe?/2 delegates to ReadOnly" do
    test "true only for a provably read-only command" do
      assert Tool.concurrency_safe?(%{"command" => "git status"}, nil)
      refute Tool.concurrency_safe?(%{"command" => "rm -rf build"}, nil)
      refute Tool.concurrency_safe?(%{"command" => "cat x > out.txt"}, nil)
    end

    test "fails closed on a malformed / missing command" do
      refute Tool.concurrency_safe?(%{}, nil)
      refute Tool.concurrency_safe?(%{"command" => nil}, nil)
    end
  end
end
