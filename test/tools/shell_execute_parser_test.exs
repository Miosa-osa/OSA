defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.ParserTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Parser
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler

  @cwd "/home/user/project"

  defp classify(cmd), do: Handler.check_permissions(%{"command" => cmd}, %{})

  # ---------------------------------------------------------------------------
  # Tokenizer + segment splitting (quote / escape / substitution awareness)
  # ---------------------------------------------------------------------------

  describe "segments/1 — quote and operator handling" do
    test "splits on ; && || |" do
      assert Parser.segments("a; b && c || d | e") |> length() == 5
    end

    test "a semicolon inside single quotes does NOT split" do
      segs = Parser.segments("echo 'a; b'")
      assert length(segs) == 1
      assert [[{:word, "echo"}, {:word, "'a; b'"}]] = segs
    end

    test "a pipe inside double quotes does NOT split" do
      segs = Parser.segments(~s(echo "a | b"))
      assert length(segs) == 1
    end

    test "operators inside $(...) do not split" do
      segs = Parser.segments("echo $(ls; pwd | wc -l)")
      assert length(segs) == 1
    end

    test "backtick substitution is one word" do
      segs = Parser.segments("echo `whoami`")
      assert [[{:word, "echo"}, {:word, "`whoami`"}]] = segs
    end

    test "escaped semicolon does not split" do
      segs = Parser.segments("echo a\\;b")
      assert length(segs) == 1
    end

    test "redirection target is captured as a redir token, not a segment split" do
      segs = Parser.segments("echo hi > out.txt")
      assert length(segs) == 1
      assert Enum.any?(hd(segs), &match?({:redir, ">"}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Arity prefixes ("always allow <prefix> *")
  # ---------------------------------------------------------------------------

  describe "arity_prefix/1" do
    test "git → 2 tokens" do
      assert Parser.arity_prefix(["git", "checkout", "main"]) == ["git", "checkout"]
    end

    test "npm run → 3 tokens" do
      assert Parser.arity_prefix(["npm", "run", "dev"]) == ["npm", "run", "dev"]
    end

    test "docker compose → 3 tokens, flags ignored" do
      assert Parser.arity_prefix(["docker", "compose", "up", "-d"]) ==
               ["docker", "compose", "up"]
    end

    test "unknown command defaults to 1 token" do
      assert Parser.arity_prefix(["frobnicate", "arg1", "arg2"]) == ["frobnicate"]
    end

    test "python takes 2 tokens per the ported table" do
      assert Parser.arity_prefix(["python", "-m", "http.server"]) == ["python", "http.server"]
    end

    test "single-arity command keeps head only" do
      assert Parser.arity_prefix(["ls", "-la", "/tmp"]) == ["ls"]
    end

    test "leading flags are dropped before matching" do
      assert Parser.arity_prefix(["-x", "git", "status"]) == ["git", "status"]
    end

    test "absolute path head is reduced to its basename" do
      assert Parser.arity_prefix(["/usr/bin/git", "status"]) == ["git", "status"]
    end
  end

  # ---------------------------------------------------------------------------
  # Path extraction / expansion
  # ---------------------------------------------------------------------------

  describe "expand_path/2" do
    test "resolves a relative path against cwd" do
      assert {:ok, "/home/user/project/src/main.ex"} =
               Parser.expand_path("src/main.ex", @cwd)
    end

    test "expands ~ to the home directory" do
      home = System.user_home()
      assert {:ok, resolved} = Parser.expand_path("~/notes.txt", @cwd)
      assert resolved == Path.join(home, "notes.txt")
    end

    test "expands $HOME and ${HOME}" do
      home = System.user_home()
      assert {:ok, ^home} = Parser.expand_path("$HOME", @cwd)
      assert {:ok, p1} = Parser.expand_path("$HOME/x", @cwd)
      assert p1 == Path.join(home, "x")
      assert {:ok, p2} = Parser.expand_path("${HOME}/y", @cwd)
      assert p2 == Path.join(home, "y")
    end

    test "strips a glob suffix to its literal prefix" do
      assert {:ok, "/home/user/project/src"} = Parser.expand_path("src/*.ex", @cwd)
    end

    test "skips a pure glob" do
      assert :skip = Parser.expand_path("*.ex", @cwd)
    end

    test "skips a dynamic $(...) argument" do
      assert :skip = Parser.expand_path("$(pwd)/x", @cwd)
    end

    test "skips a backtick argument" do
      assert :skip = Parser.expand_path("`pwd`", @cwd)
    end

    test "skips an unresolved $VAR" do
      assert :skip = Parser.expand_path("$OUT/file", @cwd)
    end
  end

  # ---------------------------------------------------------------------------
  # External-directory detection (only for file-mutating commands)
  # ---------------------------------------------------------------------------

  describe "scan/2 — external directory detection" do
    test "cp writing outside cwd flags an external directory" do
      scan = Parser.scan("cp build.txt /etc/newfile", @cwd)
      assert "/etc" in scan.external_dirs
    end

    test "mv into an external dir flags it" do
      scan = Parser.scan("mv a.txt /var/tmp/b.txt", @cwd)
      assert "/var/tmp" in scan.external_dirs
    end

    test "cp within cwd flags nothing" do
      scan = Parser.scan("cp a.txt b.txt", @cwd)
      assert scan.external_dirs == []
    end

    test "read-only cat outside cwd is NOT flagged as external" do
      scan = Parser.scan("cat /etc/os-release", @cwd)
      assert scan.external_dirs == []
    end

    test "cd outside cwd is NOT flagged (navigation, not mutation)" do
      scan = Parser.scan("cd /tmp && ls", @cwd)
      assert scan.external_dirs == []
    end

    test "a nested relative path stays inside cwd" do
      scan = Parser.scan("mkdir src/generated", @cwd)
      assert scan.external_dirs == []
    end

    test "a parent-relative mutation escapes cwd" do
      scan = Parser.scan("touch ../sibling.txt", @cwd)
      assert scan.external_dirs != []
    end
  end

  # ---------------------------------------------------------------------------
  # scan/2 — always-allow patterns are surfaced
  # ---------------------------------------------------------------------------

  describe "scan/2 — always-allow patterns" do
    test "git checkout yields a scoped prefix pattern" do
      scan = Parser.scan("git checkout main", @cwd)
      assert "git checkout *" in scan.always
    end

    test "npm run dev yields the full 3-token pattern" do
      scan = Parser.scan("npm run dev", @cwd)
      assert "npm run dev *" in scan.always
    end

    test "cd does not contribute an always-allow pattern" do
      scan = Parser.scan("cd /tmp", @cwd)
      assert scan.always == []
    end

    test "multiple segments each contribute a pattern" do
      scan = Parser.scan("git status && npm run build", @cwd)
      assert "git status *" in scan.always
      assert "npm run build *" in scan.always
    end
  end

  # ---------------------------------------------------------------------------
  # Handler wiring — structured analysis folded into the three-tier decision
  # ---------------------------------------------------------------------------

  describe "handler check_permissions wiring" do
    test "a plain safe command is still allowed" do
      assert {:allow, _} = classify("echo hello")
    end

    test "read-only cat of an external file stays allowed (no cage)" do
      assert {:allow, _} = classify("cat /etc/os-release")
    end

    test "cp writing outside cwd escalates a safe command to :ask" do
      assert {:ask, msg} = classify("cp build.txt /etc/osa_external_probe")
      assert msg =~ "outside the working directory"
    end

    test "a risky command's reason is enriched with an always-allow pattern" do
      assert {:ask, msg} = classify("git push origin main --force")
      assert msg =~ "git push *"
    end

    test "catastrophic commands remain hard-denied (scan never downgrades)" do
      assert {:deny, _} = classify("rm -rf /")
    end
  end
end
