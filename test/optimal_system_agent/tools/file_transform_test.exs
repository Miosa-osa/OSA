defmodule OptimalSystemAgent.Tools.FileTransformTest do
  @moduledoc """
  `file_transform`'s contract, with the adversarial cases first.

  The tool's whole claim is that a model can change a file it is not holding.
  That claim is only worth having if two properties hold, so they are what these
  tests are mostly about:

    1. **Confinement** — the declared path is the only path written. Not "the
       only path we expect to be written": the only one, demonstrated by
       checking that nothing else in the directory moved.
    2. **All-or-nothing** — a transform that fails leaves the file byte-identical.
       A corrupted file is worse than a refused edit, so every failure mode
       (bad anchor, wrong count, unbalanced result, malformed op, failure
       part-way through a list) is checked for it individually.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileTransform.{Handler, Ops, Tool}

  @scheme """
  (define (eval exp env)
    (cond ((self-evaluating? exp) exp)
          ((variable? exp) (lookup-variable-value exp env))
          (else (error "Unknown expression type" exp))))

  (define (caddddr p) (car (cdr (cdr (cdr (cdr p))))))

  (define (apply proc args)
    (cond ((primitive-procedure? proc) (apply-primitive proc args))
          (else (error "Unknown procedure type" proc))))
  """

  setup do
    dir =
      Path.join(System.tmp_dir!(), "osa_file_transform_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "eval.scm")
    File.write!(path, @scheme)

    # A bystander: nothing any transform does may change this file.
    bystander = Path.join(dir, "bystander.txt")
    File.write!(bystander, "untouched")

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, path: path, bystander: bystander}
  end

  defp run(input), do: Handler.execute(input, %{session_id: "ft-test"})

  defp digest(path), do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1))

  # ── Confinement: the declared path is the only path written ───────────

  describe "authorisation" do
    test "an operation whose text names another file does not touch it", ctx do
      before = digest(ctx.bystander)

      {:ok, _, _} =
        run(%{
          "path" => ctx.path,
          "operations" => [
            %{
              "op" => "append",
              "text" => "; see #{ctx.bystander} and /etc/passwd and #{ctx.dir}/new.txt"
            }
          ]
        })

      assert digest(ctx.bystander) == before
      refute File.exists?(Path.join(ctx.dir, "new.txt"))
      assert File.read!(ctx.path) =~ "; see"
    end

    test "the directory gains no file other than the target", ctx do
      before = ctx.dir |> File.ls!() |> Enum.sort()

      {:ok, _} =
        run(%{
          "path" => ctx.path,
          "operations" => [%{"op" => "replace", "find" => "cond", "to" => "cond", "expect" => 2}]
        })

      assert File.ls!(ctx.dir) |> Enum.sort() == before
    end

    test "a path outside the allowed roots is denied before anything is read" do
      assert {:deny, reason} =
               Handler.check_permissions(
                 %{"path" => "/etc/passwd", "operations" => []},
                 %{}
               )

      assert reason =~ "protected location"
    end

    test "execute/2 re-checks the path even when check_permissions is bypassed" do
      assert {:error, reason} =
               run(%{
                 "path" => "/etc/hosts",
                 "operations" => [%{"op" => "append", "text" => "evil"}]
               })

      assert reason =~ "protected location"
      refute File.read!("/etc/hosts") =~ "evil"
    end

    test "a .git internal is refused by the shared write policy", ctx do
      git = Path.join([ctx.dir, ".git"])
      File.mkdir_p!(git)
      config = Path.join(git, "config")
      File.write!(config, "[core]\n")

      assert {:error, reason} =
               run(%{
                 "path" => config,
                 "operations" => [
                   %{"op" => "append", "text" => "\thooksPath = /tmp/evil\n"}
                 ]
               })

      assert reason =~ "protected location"
      refute File.read!(config) =~ "hooksPath"
    end

    test "a symlink pointing out of the allowed roots is refused", ctx do
      link = Path.join(ctx.dir, "link.conf")
      :ok = File.ln_s("/etc/hosts", link)

      assert {:error, reason} =
               run(%{"path" => link, "operations" => [%{"op" => "append", "text" => "x"}]})

      assert reason =~ "protected location" or reason =~ "outside allowed paths"
    end

    test "the tool is on the file-mutating list, so scope and bypass-immune asks see it" do
      assert OptimalSystemAgent.Permissions.bypass_immune_ask("file_transform", %{
               "path" => "~/.zshrc"
             }) =~ "shell startup file"
    end
  end

  # ── All-or-nothing ────────────────────────────────────────────────────

  describe "atomicity" do
    test "an anchor that matches nothing writes nothing and says so", ctx do
      before = digest(ctx.path)

      assert {:error, reason} =
               run(%{
                 "path" => ctx.path,
                 "operations" => [%{"op" => "replace", "find" => "not-in-the-file", "to" => "x"}]
               })

      assert reason =~ "found 0"
      assert digest(ctx.path) == before
    end

    test "a wrong expected count writes nothing", ctx do
      before = digest(ctx.path)

      assert {:error, reason} =
               run(%{
                 "path" => ctx.path,
                 "operations" => [
                   %{"op" => "replace", "find" => "define", "to" => "def", "expect" => 99}
                 ]
               })

      assert reason =~ "expected 99"
      assert reason =~ "found 3"
      assert digest(ctx.path) == before
    end

    test "a failure part-way through a list rolls the earlier operations back", ctx do
      before = digest(ctx.path)

      assert {:error, reason} =
               run(%{
                 "path" => ctx.path,
                 "operations" => [
                   %{"op" => "append", "text" => "; first op succeeds"},
                   %{"op" => "replace", "find" => "absent", "to" => "x"},
                   %{"op" => "append", "text" => "; never reached"}
                 ]
               })

      assert reason =~ "operation 2"
      assert digest(ctx.path) == before
      refute File.read!(ctx.path) =~ "first op succeeds"
    end

    test "a transform that would unbalance the file is refused", ctx do
      before = digest(ctx.path)

      assert {:error, reason} =
               run(%{
                 "path" => ctx.path,
                 "operations" => [
                   %{"op" => "delete_matching_lines", "pattern" => "^  \\(cond", "expect" => 2},
                   %{"op" => "assert_balanced"}
                 ]
               })

      assert reason =~ "balance:"
      assert digest(ctx.path) == before
    end

    test "no staging file survives a failed transform", ctx do
      run(%{
        "path" => ctx.path,
        "operations" => [%{"op" => "replace", "find" => "no", "to" => "x"}]
      })

      refute Enum.any?(File.ls!(ctx.dir), &String.contains?(&1, "osa-transform"))
    end

    test "no staging file survives a successful transform", ctx do
      {:ok, _, _} =
        run(%{"path" => ctx.path, "operations" => [%{"op" => "append", "text" => "; ok"}]})

      refute Enum.any?(File.ls!(ctx.dir), &String.contains?(&1, "osa-transform"))
    end

    test "the file's permission bits survive the rename", ctx do
      File.chmod!(ctx.path, 0o750)

      {:ok, _, _} =
        run(%{"path" => ctx.path, "operations" => [%{"op" => "append", "text" => "; x"}]})

      assert %File.Stat{mode: mode} = File.stat!(ctx.path)
      assert rem(mode, 0o1000) == 0o750
    end
  end

  # ── Editing ───────────────────────────────────────────────────────────

  describe "operations" do
    test "delete_matching_lines removes the defective definition and keeps balance", ctx do
      assert {:ok, result, _meta} =
               run(%{
                 "path" => ctx.path,
                 "operations" => [
                   %{
                     "op" => "delete_matching_lines",
                     "pattern" => "^\\(define \\(caddddr",
                     "expect" => 1
                   },
                   %{"op" => "assert_balanced"}
                 ]
               })

      refute File.read!(ctx.path) =~ "caddddr"
      assert result =~ "1 lines deleted"
      assert result =~ "balance: 0"
    end

    test "replace_regex supports capture groups", ctx do
      {:ok, _, _} =
        run(%{
          "path" => ctx.path,
          "operations" => [
            %{
              "op" => "replace_regex",
              "pattern" => "\\(define \\((\\w+) ",
              "to" => "(define (osa_\\1 ",
              "expect" => 3
            }
          ]
        })

      assert File.read!(ctx.path) =~ "(define (osa_eval "
      assert File.read!(ctx.path) =~ "(define (osa_apply "
    end

    test "insert_after places text under every matching line", ctx do
      {:ok, _, _} =
        run(%{
          "path" => ctx.path,
          "operations" => [
            %{
              "op" => "insert_after",
              "pattern" => "^\\(define \\(eval",
              "text" => "  ; instrumented",
              "expect" => 1
            }
          ]
        })

      lines = ctx.path |> File.read!() |> String.split("\n")
      idx = Enum.find_index(lines, &String.starts_with?(&1, "(define (eval"))
      assert Enum.at(lines, idx + 1) == "  ; instrumented"
    end

    test "prepend and append respect the file's newline discipline", ctx do
      {:ok, _, _} =
        run(%{
          "path" => ctx.path,
          "operations" => [
            %{"op" => "prepend", "text" => ";; header"},
            %{"op" => "append", "text" => ";; footer"}
          ]
        })

      content = File.read!(ctx.path)
      assert String.starts_with?(content, ";; header\n(define (eval")
      assert String.ends_with?(content, ";; footer")
    end

    test "a CRLF file stays CRLF", ctx do
      crlf = Path.join(ctx.dir, "crlf.txt")
      File.write!(crlf, "alpha\r\nbeta\r\ngamma\r\n")

      {:ok, _, _} =
        run(%{
          "path" => crlf,
          "operations" => [%{"op" => "delete_matching_lines", "pattern" => "^beta$"}]
        })

      assert File.read!(crlf) == "alpha\r\ngamma\r\n"
    end
  end

  # ── Probes ────────────────────────────────────────────────────────────

  describe "probing without reading" do
    test "count reports a number and changes nothing", ctx do
      before = digest(ctx.path)

      assert {:ok, result} =
               run(%{
                 "path" => ctx.path,
                 "operations" => [%{"op" => "count", "pattern" => "\\(define"}]
               })

      assert result =~ "3 matches"
      assert result =~ "no change"
      assert digest(ctx.path) == before
    end

    test "count without an expectation cannot abort a transform", ctx do
      assert {:ok, result, _} =
               run(%{
                 "path" => ctx.path,
                 "operations" => [
                   %{"op" => "count", "pattern" => "nothing-matches-this"},
                   %{"op" => "append", "text" => "; still applied"}
                 ]
               })

      assert result =~ "0 matches"
      assert File.read!(ctx.path) =~ "still applied"
    end

    test "assert_balanced answers the well-formedness question in one line", ctx do
      assert {:ok, result} =
               run(%{"path" => ctx.path, "operations" => [%{"op" => "assert_balanced"}]})

      assert result =~ "balance: 0"
      # The whole point: the answer is bounded, and does not carry the file.
      assert byte_size(result) < 200
      assert byte_size(result) < byte_size(File.read!(ctx.path))
    end

    test "an unbalanced file reports the direction and the count", ctx do
      broken = Path.join(ctx.dir, "broken.scm")
      File.write!(broken, "(define (f x)\n  (+ x 1)\n")

      assert {:error, reason} =
               run(%{"path" => broken, "operations" => [%{"op" => "assert_balanced"}]})

      assert reason =~ "1 unclosed ("
    end

    test "dry_run reports the change and writes nothing", ctx do
      before = digest(ctx.path)

      assert {:ok, result} =
               run(%{
                 "path" => ctx.path,
                 "dry_run" => true,
                 "operations" => [
                   %{"op" => "delete_matching_lines", "pattern" => "caddddr", "expect" => 1}
                 ]
               })

      assert result =~ "DRY RUN"
      assert result =~ "would change the file"
      assert digest(ctx.path) == before
    end
  end

  # ── Input handling ────────────────────────────────────────────────────

  describe "validation" do
    test "an unknown op is rejected before any file is opened" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"path" => "x", "operations" => [%{"op" => "sudo"}]}, %{})

      assert msg =~ "unknown op"
      assert msg =~ "Known ops:"
    end

    test "an invalid regex is rejected with its offset" do
      assert {:error, msg, -32_602} =
               Handler.validate(
                 %{"path" => "x", "operations" => [%{"op" => "count", "pattern" => "([a-"}]},
                 %{}
               )

      assert msg =~ "invalid regex"
    end

    test "a missing field names the field" do
      assert {:error, msg, -32_602} =
               Handler.validate(
                 %{"path" => "x", "operations" => [%{"op" => "replace", "find" => "a"}]},
                 %{}
               )

      assert msg =~ ~s("to")
    end

    test "an empty operations list is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{"path" => "x", "operations" => []}, %{})
      assert msg =~ "empty"
    end

    test "a missing file says to use file_write instead", ctx do
      assert {:error, msg} =
               run(%{
                 "path" => Path.join(ctx.dir, "absent.scm"),
                 "operations" => [%{"op" => "append", "text" => "x"}]
               })

      assert msg =~ "no such file"
      assert msg =~ "file_write"
    end

    test "a directory target is refused", ctx do
      assert {:error, msg} =
               run(%{"path" => ctx.dir, "operations" => [%{"op" => "append", "text" => "x"}]})

      assert msg =~ "directory"
    end
  end

  # ── Wiring ────────────────────────────────────────────────────────────

  describe "tool declaration" do
    test "is registered under its name" do
      assert Tool.name() == "file_transform"
      assert Tool.always_load?()
    end

    test "a dry run is read-only, a real run is not" do
      assert Tool.read_only?(%{"dry_run" => true}, %{})
      refute Tool.read_only?(%{}, %{})
      assert Tool.destructive?(%{}, %{})
    end

    test "the description teaches the probe idiom and shows worked examples" do
      d = Tool.description()
      assert d =~ "assert_balanced"
      assert d =~ "without quoting"
      assert d =~ "expect"
      # Worked examples, not just parameter prose — the mini-swe-agent lesson.
      assert d =~ ~s({"op": "delete_matching_lines")
    end
  end

  # ── The pure layer ────────────────────────────────────────────────────

  describe "Ops" do
    test "apply_all stops at the first failing operation" do
      assert {:error, msg} =
               Ops.apply_all("abc", [
                 %{"op" => "append", "text" => "d"},
                 %{"op" => "replace", "find" => "zzz", "to" => "y"}
               ])

      assert msg =~ "operation 2"
    end

    test "an empty file appends cleanly" do
      assert {:ok, "hello", _} = Ops.apply_all("", [%{"op" => "append", "text" => "hello"}])
    end

    test "deleting every line leaves an empty file, not a stray newline" do
      assert {:ok, "", _} =
               Ops.apply_all("a\nb\n", [%{"op" => "delete_matching_lines", "pattern" => "."}])
    end
  end
end
