defmodule OptimalSystemAgent.ReleasePipelineContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The release pipeline must stay internally consistent, and the native helper
  build must stay installable on the runner image.

  Both assertions here guard a defect that shipped a broken release pipeline
  rather than a broken product, which is the worst kind: it fails at TAG time,
  when the version is already public.

  ## Why this test exists

  **1. The apt ordering.** `linux-helper` failed on every run with

      libgstreamer1.0-dev : Depends: libunwind-dev
      E: Unable to correct problems, you have held broken packages.

  MEASURED on ubuntu-22.04 (runner image 20260907.292.1, run 34670653343):
  the image preinstalls `libunwind-14-dev` (LLVM 14's versioned unwinder dev
  package), which declares

      Replaces: libunwind-dev
      Breaks:   libunwind-dev

  so installing `libunwind-dev` requires REMOVING `libunwind-14-dev` (and the
  `libc++-dev` / `libc++-14-dev` that depend on it). apt will not remove an
  installed package as a side effect of resolving a dependency inside a
  combined transaction, so asking for `libgstreamer1.0-dev` alone dead-ends.
  Naming `libunwind-dev` as an explicit target authorises the replacement, and
  the chain then resolves — confirmed by a real helper build in the same run.

  This is a RUNNER-IMAGE fact, not a Docker one: a bare `ubuntu:22.04`
  container does not ship `libunwind-14-dev`, so the combined install succeeds
  there. That is exactly why it could only ever be caught in CI, and why the
  guard belongs in the suite rather than in a comment.

  `release.yml` runs the same install on the same image, so an ordering
  regression here does not merely fail a helper build — it fails
  `build-linux-x64`, and the publish gate then refuses to publish, producing a
  tag with no assets (the v1.0.191 failure mode).

  **2. The asset contract.** The publish gate refuses to publish unless every
  asset it names exists, and `install.sh` / `install.ps1` fetch assets by name.
  A name in the gate that no build job produces is an unconditional release
  failure; an asset that exists but is not in the gate ships unverified. Both
  are silent until tag time.
  """

  @release_yml ".github/workflows/release.yml"
  @helper_yml ".github/workflows/linux-wayland-helper.yml"

  # The apt line that pulls in the GStreamer development headers. Kept as one
  # string so the ordering assertion reads as "this must not come before that".
  @gstreamer_dev "libgstreamer1.0-dev"

  defp read!(path) do
    assert File.exists?(path), "#{path} is missing — the release pipeline moved?"
    File.read!(path)
  end

  # Every line that installs packages, in file order.
  defp apt_install_lines(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "apt-get install"))
  end

  # The producer surface of the workflow: its own text, plus the text of every
  # script it invokes. Asset names are often created INSIDE a helper (the
  # Windows enrollment bundle names its output in
  # `scripts/windows/Build-EnrollmentBundle.ps1`), so searching the workflow
  # alone would report a producer that exists as missing.
  defp producer_sources(yaml) do
    # The gate's own list must NOT count as a producer, or every name in it
    # trivially "produces itself" and the assertion can never fail. This is not
    # hypothetical: the first version of this test passed with a deliberately
    # bogus asset added to the gate, because the search matched the gate line.
    yaml = String.replace(yaml, ~r/for f in \\.*?\n\s*do\b/s, "")

    scripts =
      yaml
      |> String.split("\n")
      |> Enum.flat_map(&Regex.scan(~r{[A-Za-z0-9_./-]+\.(?:sh|ps1|psm1)}, &1))
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(&File.read!/1)

    [yaml | scripts]
  end

  describe "the GStreamer dev install survives the runner image" do
    for workflow <- [@helper_yml, @release_yml] do
      test "#{workflow} installs libunwind-dev before the GStreamer dev packages" do
        yaml = read!(unquote(workflow))
        lines = apt_install_lines(yaml)

        gs_index =
          Enum.find_index(lines, &String.contains?(&1, @gstreamer_dev))

        assert gs_index,
               "#{unquote(workflow)} no longer installs #{@gstreamer_dev} at all. " <>
                 "If the helper stopped needing GStreamer, remove this test AND the " <>
                 "build step together — do not leave one without the other."

        libunwind_index =
          Enum.find_index(lines, &String.contains?(&1, "libunwind-dev"))

        assert libunwind_index,
               "#{unquote(workflow)} installs #{@gstreamer_dev} without installing " <>
                 "`libunwind-dev` first. On ubuntu-22.04 the image preinstalls " <>
                 "`libunwind-14-dev`, which Breaks/Replaces `libunwind-dev`, and apt " <>
                 "will not remove it as a side effect of resolving a dependency in a " <>
                 "combined transaction. The install fails with \"held broken packages\" " <>
                 "and — in release.yml — takes the whole release down with it."

        assert libunwind_index < gs_index,
               "#{unquote(workflow)} installs `libunwind-dev` AFTER the GStreamer dev " <>
                 "packages. It must come first and in its own transaction, or apt's " <>
                 "resolver dead-ends on the preinstalled `libunwind-14-dev`."
      end
    end

    test "the two workflows install the same GStreamer package set" do
      # They must agree: linux-helper is the early-warning signal for
      # release.yml. If they drift, a green helper build stops proving anything
      # about the release build.
      wanted = fn yaml ->
        yaml
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, @gstreamer_dev))
        |> Enum.flat_map(&String.split(&1, ~r/\s+/))
        |> Enum.filter(&String.starts_with?(&1, "libgstreamer"))
        |> Enum.map(&String.trim_trailing(&1, "\\"))
        |> Enum.sort()
        |> Enum.uniq()
      end

      helper = wanted.(read!(@helper_yml))
      release = wanted.(read!(@release_yml))

      assert helper == release,
             "linux-helper and release.yml install different GStreamer packages:\n" <>
               "  helper:  #{inspect(helper)}\n" <>
               "  release: #{inspect(release)}\n" <>
               "The helper workflow exists to fail BEFORE the release does, so they " <>
               "must install the same set."
    end
  end

  describe "every asset the publish gate requires has a producer" do
    setup do
      yaml = read!(@release_yml)

      # The gate's own list: the `for f in \ ... ; do` loop that populates
      # `missing`. Read as data so a new required asset is covered automatically.
      required =
        case Regex.run(~r/for f in \\\n(.*?)\n\s*do\b/s, yaml) do
          [_, body] ->
            body
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.map(&String.trim_trailing(&1, "\\"))
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          _ ->
            []
        end

      {:ok, yaml: yaml, required: required}
    end

    test "the gate names at least one asset per shipping platform", %{required: required} do
      assert length(required) >= 3, "the publish gate lists #{length(required)} assets"

      for platform <- ~w(linux-x64 macos-arm64 windows-x64) do
        assert Enum.any?(required, &String.contains?(&1, platform)),
               "the publish gate requires no asset for #{platform}"
      end
    end

    test "each required asset is produced somewhere in the workflow", %{
      yaml: yaml,
      required: required
    } do
      # An asset in the gate that nothing creates is an unconditional release
      # failure: the gate can never be satisfied, so the release never
      # publishes. This walks the workflow's producer surface — inline commands
      # AND the scripts those commands invoke — so a name produced inside a
      # helper script still counts.
      producers = producer_sources(yaml)

      for asset <- required do
        name = asset |> String.trim_trailing("\\") |> String.trim()

        assert Enum.any?(producers, &String.contains?(&1, name)),
               "the publish gate requires `#{name}`, but nothing in release.yml or the " <>
                 "scripts it invokes produces a file by that name. The gate can never " <>
                 "be satisfied, so every release would fail with \"Refusing to publish " <>
                 "... missing release assets\".\n\n" <>
                 "Searched: release.yml plus #{length(producers) - 1} script(s) it invokes."
      end
    end

    test "the gate requires a .sha256 sidecar for every asset it names", %{
      yaml: yaml
    } do
      # `install.sh` verifies against the sidecar; an asset without one is not
      # installable, so the gate checks both. Assert the loop still checks both.
      assert yaml =~ ~r/for a in "\$f" "\$f\.sha256"/,
             "the publish gate no longer checks the .sha256 sidecar alongside each " <>
               "asset. An asset without a sidecar is not installable — install.sh " <>
               "verifies against it — so it must stay a publish condition."
    end
  end

  describe "the installers agree with the asset naming the gate enforces" do
    test "install.sh and install.ps1 derive asset names rather than hardcoding a list" do
      # They build `osa-<platform>.tar.gz` / `osagent-tui-<platform>` from a
      # platform variable, so adding a platform asset does not require editing
      # them. Assert the derivation still holds: a hardcoded list here is how an
      # installer silently stops being able to fetch a new asset.
      sh = read!("scripts/install.sh")
      ps = read!("scripts/install.ps1")

      assert sh =~ ~r/TARBALL="osa-\$\{PLATFORM\}\.tar\.gz"/,
             "install.sh no longer derives the tarball name from PLATFORM"

      assert sh =~ ~r/TUI_ASSET="osagent-tui-\$\{PLATFORM\}"/,
             "install.sh no longer derives the TUI asset name from PLATFORM"

      assert ps =~ ~r/\$Zip\s*=\s*"osa-\$Platform\.zip"/,
             "install.ps1 no longer derives the zip name from Platform"

      assert ps =~ ~r/\$TuiAsset\s*=\s*"osagent-tui-\$Platform\.exe"/,
             "install.ps1 no longer derives the TUI asset name from Platform"
    end

    test "the Windows enrollment bundle the gate requires is actually buildable" do
      # The bundle is assembled from these inputs. If one is renamed or removed
      # the Windows job throws and the gate refuses to publish.
      bundle = read!("scripts/windows/Build-EnrollmentBundle.ps1")

      for input <-
            ~w(Install-OpenComputer.ps1 Run-OpenComputer.ps1 OpenComputerHost.psm1 WindowsHostPlatform.psm1) do
        assert bundle =~ input, "the enrollment bundle no longer copies #{input}"

        assert File.exists?("scripts/windows/#{input}"),
               "scripts/windows/#{input} is missing but the bundle copies it"
      end

      assert File.exists?("scripts/install.ps1"),
             "the bundle copies ../install.ps1, which no longer exists"
    end
  end
end
