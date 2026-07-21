defmodule OptimalSystemAgent.Agent.FleetAdversarialTest do
  @moduledoc """
  Adversarial correctness tests for the fleet/orchestration logic — probing the
  edge shapes the happy-path suite skips.

  Primary target: the `git status --porcelain -z` parser used to derive a
  worktree node's `files_changed`. The `-z` format emits rename/copy entries as
  TWO NUL-separated fields — a status-prefixed destination followed by a BARE
  origin path with NO prefix. The original implementation stripped a fixed
  3-byte prefix from EVERY field, corrupting the origin path of any rename (e.g.
  `lib/old.ex` -> `/old.ex`). That corrupted path then flows into the
  Finalizer's `git checkout <ref> -- <path>` merge and fails the whole
  finalize. These tests pin the corrected sequential parser.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Fleet

  describe "parse_porcelain_z/1 — NUL / XY-prefix / rename handling" do
    test "a simple modified entry strips the 3-char XY prefix" do
      assert Fleet.parse_porcelain_z("M  lib/a.ex\0") == ["lib/a.ex"]
    end

    test "worktree-only modified (leading-space XY) is handled" do
      assert Fleet.parse_porcelain_z(" M lib/a.ex\0") == ["lib/a.ex"]
    end

    test "untracked (??) entries keep their full path" do
      assert Fleet.parse_porcelain_z("?? new_file.ex\0") == ["new_file.ex"]
    end

    test "REGRESSION: a rename yields BOTH clean paths, never a corrupted origin" do
      # -z rename: `R  <dest>\0<origin>\0` — origin has NO status prefix.
      out = "R  lib/new.ex\0lib/old.ex\0"
      paths = Fleet.parse_porcelain_z(out)

      assert "lib/new.ex" in paths
      assert "lib/old.ex" in paths
      # The old naive parser produced this corrupted origin (first 3 bytes cut).
      refute "/old.ex" in paths
      refute "old.ex" in paths
    end

    test "a copy (C) also consumes its bare origin field verbatim" do
      out = "C  lib/dst.ex\0lib/src.ex\0"
      paths = Fleet.parse_porcelain_z(out)

      assert "lib/dst.ex" in paths
      assert "lib/src.ex" in paths
      refute "/src.ex" in paths
    end

    test "rename interleaved with a normal modify does not desync the stream" do
      # If the rename's origin field were treated as its own entry, the trailing
      # modified path would be mis-parsed. Sequential consumption keeps alignment.
      out = "R  a/new.ex\0a/old.ex\0M  b/changed.ex\0"
      paths = Fleet.parse_porcelain_z(out)

      assert "a/new.ex" in paths
      assert "a/old.ex" in paths
      assert "b/changed.ex" in paths
      # No corruption leaked from mis-stripping the bare origin.
      refute Enum.any?(paths, &String.starts_with?(&1, "/"))
    end

    test "empty / clean tree parses to []" do
      assert Fleet.parse_porcelain_z("") == []
    end

    test "de-duplicates repeated paths" do
      out = "M  dup.ex\0A  dup.ex\0"
      assert Fleet.parse_porcelain_z(out) == ["dup.ex"]
    end

    test "malformed short field is skipped, not sliced into garbage" do
      # A stray sub-3-byte token must not crash or produce a slice artifact.
      out = "M  lib/ok.ex\0xy\0"
      assert Fleet.parse_porcelain_z("" <> out) == ["lib/ok.ex"]
    end

    test "non-binary input degrades to []" do
      assert Fleet.parse_porcelain_z(nil) == []
    end
  end
end
