# typed: false
# frozen_string_literal: true

# Homebrew formula for OSA (osagent alias).
#
# NOTE: This formula is normally consumed from a tap
# (`brew install Miosa-osa/tap/osagent`). The canonical home for it is the
# homebrew-miosa-osa/tap repository — the copy kept here in the main repo is a
# reference/source-of-truth. See CONTRIBUTING for the tap-sync process.
#
# `osa`, `osagent`, and `miosa` are three aliases for the same tool. Keeping
# three near-identical formulas is redundant; long term, prefer a single tapped
# formula (`osa`) that installs all three command symlinks.
#
# The download tag is `v1.0.078` while the Homebrew `version` is `1.0.78`
# (Homebrew rejects the zero-padded form), so the release URL pins the tag
# explicitly instead of interpolating `#{version}`.
#
# Only the two published release platforms are wired up: macOS arm64 (Apple
# Silicon) and Linux x86_64. There is no macOS Intel or Linux arm64 tarball in
# the v1.0.078 release, so `brew install` on those platforms is unsupported.
class Osagent < Formula
  desc "Signal Theory-optimized AI agent - your OS, supercharged"
  homepage "https://github.com/Miosa-osa/OSA"
  version "1.0.78"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/Miosa-osa/OSA/releases/download/v1.0.078/osa-macos-arm64.tar.gz"
      sha256 "3e883f15ae7b768431ba3dc500025cde91430531e52d9c19bdca80750b930d8b"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/Miosa-osa/OSA/releases/download/v1.0.078/osa-linux-x64.tar.gz"
      sha256 "8749df6ee016303b28022730b37e60c32ef2a01c1e3a53b7dadd8c7e43da35ea"
    end
  end

  conflicts_with "osa", because: "both formulas install the OSA command-line tools"
  conflicts_with "miosa", because: "both formulas install the OSA command-line tools"

  def install
    # The release tarball is a self-contained Elixir release (bundled ERTS)
    # built via `MIX_ENV=prod mix release osagent`; its launcher is bin/osagent.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/osagent" => "osagent"
    bin.install_symlink libexec/"bin/osagent" => "osa"
    bin.install_symlink libexec/"bin/osagent" => "miosa"
  end

  def caveats
    <<~EOS
      OSA installed the following commands:
        osa
        osagent
        miosa

      First run kicks off onboarding (picks a provider and seeds ~/.osa/).
      The standalone TUI ships as a separate release asset (osagent-tui-<platform>).
    EOS
  end

  test do
    # Best-effort smoke test: the launcher should print a version-like string.
    assert_match(/\d+\.\d+/, shell_output("#{bin}/osagent version"))
  end
end
