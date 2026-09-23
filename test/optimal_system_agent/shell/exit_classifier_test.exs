defmodule OptimalSystemAgent.Shell.ExitClassifierTest do
  @moduledoc """
  `grep`/`rg`/`diff`/`cmp`/`test` exit 1 is a normal,
  meaningful answer (no matches / differs / false) and must not be reported
  as a background-command FAILURE. See `ExitClassifier` moduledoc.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Shell.ExitClassifier

  describe "benign_exit?/2 — grep family, exit 1 = no matches" do
    test "grep" do
      assert ExitClassifier.benign_exit?("grep TODO file.ex", 1)
    end

    test "egrep/fgrep/rg" do
      assert ExitClassifier.benign_exit?("egrep 'TODO|FIXME' file.ex", 1)
      assert ExitClassifier.benign_exit?("fgrep TODO file.ex", 1)
      assert ExitClassifier.benign_exit?("rg TODO .", 1)
    end

    test "a real grep error (exit 2) is NOT benign" do
      refute ExitClassifier.benign_exit?("grep TODO /no/such/file", 2)
    end
  end

  describe "benign_exit?/2 — diff/cmp, exit 1 = differs" do
    test "diff" do
      assert ExitClassifier.benign_exit?("diff a.txt b.txt", 1)
    end

    test "cmp" do
      assert ExitClassifier.benign_exit?("cmp a.bin b.bin", 1)
    end

    test "diff exit 2 (real error) is NOT benign" do
      refute ExitClassifier.benign_exit?("diff a.txt /no/such/file", 2)
    end
  end

  describe "benign_exit?/2 — test/[, exit 1 = false" do
    test "test" do
      assert ExitClassifier.benign_exit?("test -f /no/such/file", 1)
    end

    test "[ ... ]" do
      assert ExitClassifier.benign_exit?("[ -f /no/such/file ]", 1)
    end
  end

  describe "benign_exit?/2 — an ordinary command's exit 1 IS a failure" do
    test "a script exiting 1 is not reclassified" do
      refute ExitClassifier.benign_exit?("./deploy.sh", 1)
    end

    test "npm test exit 1 (failing suite) is not reclassified" do
      refute ExitClassifier.benign_exit?("npm test", 1)
    end
  end

  describe "benign_exit?/2 — pipelines: classify by the LAST stage" do
    test "grep piped into a benign-irrelevant tail is classified by the tail" do
      # `grep ... | wc -l` reports wc's exit code, not grep's — wc exit 1 is a
      # real failure, so this must NOT be reclassified even though grep is
      # present earlier in the pipeline.
      refute ExitClassifier.benign_exit?("grep TODO file.ex | wc -l", 1)
    end

    test "a pipeline ending in grep is classified by grep" do
      assert ExitClassifier.benign_exit?("cat file.ex | grep TODO", 1)
    end

    test "a pipeline ending in diff is classified by diff" do
      assert ExitClassifier.benign_exit?("cat a.txt | diff - b.txt", 1)
    end
  end

  describe "benign_exit?/2 — ambiguous compound commands are left unclassified" do
    test "grep && echo done — exit code could belong to either branch" do
      refute ExitClassifier.benign_exit?("grep TODO file.ex && echo done", 1)
    end

    test "grep; echo done — sequential, exit code is the LAST command's" do
      refute ExitClassifier.benign_exit?("grep TODO file.ex; echo done", 1)
    end

    test "grep || true" do
      refute ExitClassifier.benign_exit?("grep TODO file.ex || true", 1)
    end

    test "backgrounded with &" do
      refute ExitClassifier.benign_exit?("grep TODO file.ex &", 1)
    end
  end

  describe "benign_exit?/2 — exit code 0 is never routed here" do
    test "exit 0 is not benign (the caller already treats it as :done)" do
      refute ExitClassifier.benign_exit?("grep TODO file.ex", 0)
    end
  end

  describe "benign_exit?/2 — a full path to the binary still resolves" do
    test "/usr/bin/grep" do
      assert ExitClassifier.benign_exit?("/usr/bin/grep TODO file.ex", 1)
    end
  end
end
