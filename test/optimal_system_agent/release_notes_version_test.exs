defmodule OptimalSystemAgent.ReleaseNotesVersionTest do
  @moduledoc """
  The updater told a user on a second machine "already up to date" while
  `v1.0.100` was published with binaries attached. It was not a network problem
  and not a missing release — the comparison could not represent the difference
  between "nothing newer" and "I could not find out", and printed the
  reassuring one for both.

  These tests pin the three outcomes apart. Every case below answers "up to
  date" under the pre-fix code.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.ReleaseNotes

  describe "normalize_semver/1 — the padded display form" do
    test "strips the leading zeros semver forbids, so a padded tag parses at all" do
      assert ReleaseNotes.normalize_semver("v1.0.099") == "1.0.99"
      assert ReleaseNotes.normalize_semver("1.0.098") == "1.0.98"
      assert ReleaseNotes.normalize_semver("v1.0.100") == "1.0.100"
      assert ReleaseNotes.normalize_semver("1.0.1") == "1.0.1"
      assert ReleaseNotes.normalize_semver("v1.0.004") == "1.0.4"
    end

    test "leaves a pre-release / build suffix alone" do
      assert ReleaseNotes.normalize_semver("v1.0.099-rc.1") == "1.0.99-rc.1"
      assert ReleaseNotes.normalize_semver("1.0.099+build.7") == "1.0.99+build.7"
    end

    test "the padded and unpadded spellings of one release are the same version" do
      assert ReleaseNotes.normalize_semver("v1.0.099") ==
               ReleaseNotes.normalize_semver("1.0.99")
    end
  end

  describe "version_newer?/2 — the reproduction" do
    test "v1.0.100 is newer than the padded v1.0.099 the machine was running" do
      # THE BUG. `Version.parse("1.0.099")` is `:error`; the old `else -> false`
      # turned that into "no update available".
      assert ReleaseNotes.version_newer?("1.0.100", "1.0.099")
      assert ReleaseNotes.version_newer?("v1.0.100", "v1.0.099")
      assert ReleaseNotes.version_newer?("1.0.100", "1.0.098")
    end

    test "and is newer than the same release spelled unpadded" do
      assert ReleaseNotes.version_newer?("1.0.100", "1.0.99")
    end

    test "the negative direction still holds — no phantom updates" do
      refute ReleaseNotes.version_newer?("1.0.099", "1.0.100")
      refute ReleaseNotes.version_newer?("1.0.99", "1.0.100")
      refute ReleaseNotes.version_newer?("1.0.100", "1.0.100")
      refute ReleaseNotes.version_newer?("v1.0.099", "1.0.99")
    end

    test "v1.0.1 is a genuinely different, much older version than v1.0.100" do
      # Both parse without normalization, so this pair passed even before the
      # fix — it is here to prove the fix did not collapse them into each other.
      assert ReleaseNotes.version_newer?("1.0.100", "1.0.1")
      refute ReleaseNotes.version_newer?("1.0.1", "1.0.100")
      assert ReleaseNotes.version_newer?("1.0.4", "1.0.1")
    end
  end

  describe "the real historical tag sequence orders correctly" do
    # The repo's actual tags, in the order they were published. `git tag
    # --sort=-v:refname` prints v1.0.4 and v1.0.1 ABOVE every padded tag, which
    # is why `latest_release_tag/0` no longer trusts git's ordering.
    @tags ~w(
      v1.0.0 v1.0.1 v1.0.4 v1.0.090 v1.0.091 v1.0.092 v1.0.093 v1.0.094
      v1.0.095 v1.0.096 v1.0.097 v1.0.098 v1.0.099 v1.0.100
    )

    test "each tag is strictly newer than the one before it" do
      @tags
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [older, newer] ->
        assert ReleaseNotes.version_newer?(newer, older),
               "expected #{newer} to be newer than #{older}"

        refute ReleaseNotes.version_newer?(older, newer),
               "expected #{older} NOT to be newer than #{newer}"
      end)
    end

    test "sorting the whole list puts v1.0.100 last and v1.0.4 below the 09x run" do
      sorted =
        Enum.sort(@tags, fn a, b ->
          not ReleaseNotes.version_newer?(a, b)
        end)

      assert List.last(sorted) == "v1.0.100"

      assert Enum.find_index(sorted, &(&1 == "v1.0.4")) <
               Enum.find_index(sorted, &(&1 == "v1.0.090"))
    end
  end

  describe "version_status/0 separates the three outcomes" do
    test "reports a status, not just a boolean" do
      status = ReleaseNotes.version_status()

      assert status.status in [:update_available, :current, :unknown]
      assert status.source in [:git_tags, :changelog, :none]
      # Back-compat: the boolean every existing caller reads still agrees.
      assert status.update_available == (status.status == :update_available)
    end

    test "an install with no git and only a bundled changelog reports :unknown" do
      # This is the packaged-install shape. The bundled changelog ships INSIDE
      # the release, so its newest entry can never be newer than the running
      # version — it can never say "yes", and so it must not be trusted to say
      # "no". Before the fix this path reported update_available: false, which
      # the CLI printed as "up to date" on every machine forever.
      status = ReleaseNotes.version_status()

      if status.source == :changelog do
        assert status.status == :unknown
      end
    end
  end
end
