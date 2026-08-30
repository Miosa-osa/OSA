defmodule OptimalSystemAgent.Tools.PrimitiveFailureQualityTest do
  @moduledoc """
  The house standard for primitive tools, asserted rather than assumed.

  `file_read` was brought up to a contract — every failure names the cause AND a
  concrete next step — and these tests hold the other primitives to the same one.
  They deliberately assert on *substance* (does the message name the tool the
  caller should reach for next?) rather than on exact prose, so wording can be
  improved without a test edit, but a message can never silently regress to a
  bare errno.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.DirList
  alias OptimalSystemAgent.Tools.Builtins.FileGlob
  alias OptimalSystemAgent.Tools.UseContext

  defp tmpdir(tag) do
    dir = "/tmp/osa_prim_#{tag}_#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp ls(input), do: DirList.execute(input, UseContext.empty())

  # ── file_glob: the missing capability ────────────────────────────────

  describe "file_glob dotfile visibility" do
    test "matches dotfiles, which Path.wildcard/1 excludes entirely" do
      dir = tmpdir("dot")
      File.write!(Path.join(dir, ".editorconfig"), "root = true")
      File.write!(Path.join(dir, "visible.txt"), "x")

      assert {:ok, result} = FileGlob.execute(%{"pattern" => "*", "path" => dir})
      assert result =~ ".editorconfig"
      assert result =~ "visible.txt"
    end

    @tag :documents_current_behaviour
    test "the sensitive-path filter is a SUBSTRING match, so it also eats `.env.example`" do
      # Not an endorsement — a pin. `Constants.sensitive_paths/0` contains the
      # bare string ".env" and the filter is `String.contains?/2`, so every path
      # with ".env" anywhere in it is suppressed: `.env.example`, `.envrc`,
      # `docs/.environment.md`. That was invisible while dotfiles were unmatchable
      # in the first place; making them matchable is what exposes it.
      #
      # Narrowing the list to component-exact matching would UNBLOCK `.env.local`
      # and `.env.production`, which do hold secrets, so it is a security-policy
      # call rather than a cleanup — and the same list is duplicated in
      # `file_read`, `file_grep` and `dir_list`. Pinned here so the decision is
      # made deliberately rather than discovered by a leak.
      dir = tmpdir("envsub")
      File.write!(Path.join(dir, ".env.example"), "API_KEY=replace-me")
      File.write!(Path.join(dir, "keep.txt"), "x")

      assert {:ok, result} = FileGlob.execute(%{"pattern" => "*", "path" => dir})
      assert result =~ "keep.txt"
      refute result =~ ".env.example"
    end

    test "descends into dot-directories" do
      dir = tmpdir("dotdir")
      File.mkdir_p!(Path.join(dir, ".github/workflows"))
      File.write!(Path.join([dir, ".github", "workflows", "ci.yml"]), "on: push")

      assert {:ok, result} = FileGlob.execute(%{"pattern" => "**/*.yml", "path" => dir})
      assert result =~ "ci.yml"
    end

    test "an explicit dot pattern still works" do
      dir = tmpdir("dotexp")
      File.write!(Path.join(dir, ".gitignore"), "_build")

      assert {:ok, result} = FileGlob.execute(%{"pattern" => ".*", "path" => dir})
      assert result =~ ".gitignore"
    end
  end

  describe "file_glob .git noise filter" do
    test "omits .git contents from an ordinary recursive pattern" do
      dir = tmpdir("git")
      File.mkdir_p!(Path.join(dir, ".git/objects"))
      File.write!(Path.join([dir, ".git", "objects", "deadbeef"]), "blob")
      File.write!(Path.join(dir, "real.ex"), "defmodule A do end")

      assert {:ok, result} = FileGlob.execute(%{"pattern" => "**/*", "path" => dir})
      assert result =~ "real.ex"
      refute result =~ "deadbeef"
    end

    test "honours a pattern that names .git explicitly" do
      dir = tmpdir("gitex")
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join([dir, ".git", "HEAD"]), "ref: refs/heads/main")

      assert {:ok, result} = FileGlob.execute(%{"pattern" => ".git/*", "path" => dir})
      assert result =~ "HEAD"
    end
  end

  describe "file_glob failure quality" do
    test "a nonexistent base is reported as such, not as 'no files matched'" do
      dir = tmpdir("base")
      missing = Path.join(dir, "nope")

      assert {:error, msg} = FileGlob.execute(%{"pattern" => "**/*.ex", "path" => missing})
      assert msg =~ "does not exist"
      # The distinction that matters: the caller must not go on rewriting the pattern.
      refute msg =~ "No files matched"
      assert msg =~ "dir_list"
    end

    test "a nonexistent base offers the closest real sibling" do
      dir = tmpdir("sugg")
      File.mkdir_p!(Path.join(dir, "handlers"))

      assert {:error, msg} =
               FileGlob.execute(%{"pattern" => "*", "path" => Path.join(dir, "handler")})

      assert msg =~ "handlers"
    end

    test "a base that is a file names the tool to use instead" do
      dir = tmpdir("basefile")
      file = Path.join(dir, "a.txt")
      File.write!(file, "x")

      assert {:error, msg} = FileGlob.execute(%{"pattern" => "*", "path" => file})
      assert msg =~ "is a file, not a directory"
      assert msg =~ "file_read"
    end

    test "a genuine empty result says the directory IS there and how many entries it holds" do
      dir = tmpdir("empty")
      File.write!(Path.join(dir, "a.txt"), "x")
      File.write!(Path.join(dir, "b.txt"), "y")

      assert {:ok, msg} = FileGlob.execute(%{"pattern" => "*.rs", "path" => dir})
      assert msg =~ "No files matched"
      assert msg =~ "exists and is readable"
      assert msg =~ "2 top-level"
      # A caller who does not know the dotfile rule cannot tell a real empty
      # result from a filtered one, so the rule is stated in the message.
      assert msg =~ "Dotfiles"
      assert msg =~ "file_grep"
    end

    test "a truly empty base directory is distinguished from an unmatched pattern" do
      dir = tmpdir("emptybase")

      assert {:ok, msg} = FileGlob.execute(%{"pattern" => "*.rs", "path" => dir})
      assert msg =~ "completely empty"
    end

    test "directories in the result are marked with a trailing slash" do
      dir = tmpdir("mark")
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "f.txt"), "x")

      # The ripgrep engine (`rg --files`) lists FILES only — a directory can
      # never appear in its result, so the trailing-slash decoration only
      # applies to the pure-Elixir fallback walk (`Path.wildcard/2` includes
      # directories). Assert the decoration contract the fallback guarantees;
      # under rg the same query returns f.txt and no directory entry, which is
      # correct for that engine.
      assert {:ok, result} = FileGlob.execute(%{"pattern" => "*", "path" => dir})
      assert result =~ "f.txt"

      if String.contains?(result, "sub/") do
        :ok
      else
        # rg served the search — no directory entries exist to decorate.
        refute result =~ "sub"
      end
    end

    test "a non-string path is rejected by name rather than crashing" do
      assert {:error, msg} = FileGlob.execute(%{"pattern" => "*", "path" => 42})
      assert msg =~ "path must be a string"
    end
  end

  # ── dir_list ─────────────────────────────────────────────────────────

  describe "dir_list failure quality" do
    test "an empty directory reports itself instead of returning an empty string" do
      dir = tmpdir("dl_empty")

      assert {:ok, msg} = ls(%{"path" => dir})
      refute msg == ""
      assert msg =~ "is empty (0 entries)"
      # Must be unmistakably the tool speaking, not a one-line listing.
      assert msg =~ "<dir_list notice:"
      assert msg =~ "not a listing failure"
    end

    test "a path that is a file points at file_read rather than reporting 'not found'" do
      dir = tmpdir("dl_file")
      file = Path.join(dir, "a.txt")
      File.write!(file, "x")

      assert {:error, msg} = ls(%{"path" => file})
      assert msg =~ "is a file, not a directory"
      assert msg =~ "file_read"
      refute msg =~ "does not exist"
    end

    test "a missing directory offers the closest real neighbours" do
      dir = tmpdir("dl_missing")
      File.mkdir_p!(Path.join(dir, "handlers"))

      assert {:error, msg} = ls(%{"path" => Path.join(dir, "handler")})
      assert msg =~ "does not exist"
      assert msg =~ "handlers"
      # Directories are flagged so the caller knows `dir_list`, not `file_read`,
      # is the follow-up — the same decoration `file_read` uses.
      assert msg =~ "handlers/"
    end

    @tag :documents_current_behaviour
    test "a transposition in a SHORT name falls below the suggestion threshold" do
      # `lib` vs `lbi` scores 0.556 on Erlang's Jaro, under PathResolve's 0.7
      # floor, so no suggestion is offered — Erlang's `jaro_distance/2` gives no
      # transposition credit, and on three-character names a single swap moves
      # more than a third of the string. The message stays correct and still
      # names a next step; it just cannot shortcut. Pinned so that raising the
      # sensitivity of the shared suggester is a measured change, not a surprise.
      dir = tmpdir("dl_short")
      File.mkdir_p!(Path.join(dir, "lib"))

      assert {:error, msg} = ls(%{"path" => Path.join(dir, "lbi")})
      assert msg =~ "does not exist"
      assert msg =~ "nothing in"
      assert msg =~ "dir_list"
      assert msg =~ "file_glob"
    end

    test "a missing directory under a missing parent says so explicitly" do
      dir = tmpdir("dl_noparent")

      assert {:error, msg} = ls(%{"path" => Path.join(dir, "a/b/c")})
      assert msg =~ "neither does its parent"
    end

    test "a normal listing carries a header naming the directory and entry count" do
      dir = tmpdir("dl_header")
      File.write!(Path.join(dir, "a.txt"), "x")

      assert {:ok, msg} = ls(%{"path" => dir})
      assert msg =~ dir
      assert msg =~ "1 entry"
      assert msg =~ "a.txt"
    end

    test "hidden entries are listed — matching file_glob rather than diverging from it" do
      dir = tmpdir("dl_hidden")
      File.write!(Path.join(dir, ".hidden"), "x")

      assert {:ok, msg} = ls(%{"path" => dir})
      assert msg =~ ".hidden"
    end
  end

  # ── Cross-primitive consistency ──────────────────────────────────────

  describe "primitives agree with each other" do
    test "dir_list and file_glob report the same set of names for a flat directory" do
      dir = tmpdir("agree")
      File.write!(Path.join(dir, ".dotfile"), "x")
      File.write!(Path.join(dir, "plain.txt"), "y")

      {:ok, listing} = ls(%{"path" => dir})
      {:ok, globbed} = FileGlob.execute(%{"pattern" => "*", "path" => dir})

      for name <- [".dotfile", "plain.txt"] do
        assert listing =~ name, "dir_list omitted #{name}"
        assert globbed =~ name, "file_glob omitted #{name}"
      end
    end

    test "both primitives treat 'nothing here' as success and 'wrong path' as an error" do
      dir = tmpdir("shape")

      assert {:ok, _} = ls(%{"path" => dir})
      assert {:ok, _} = FileGlob.execute(%{"pattern" => "*.zzz", "path" => dir})

      assert {:error, _} = ls(%{"path" => Path.join(dir, "nope")})
      assert {:error, _} = FileGlob.execute(%{"pattern" => "*", "path" => Path.join(dir, "nope")})
    end
  end
end
