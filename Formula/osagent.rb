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
# The download tag is `v1.0.002` while the Homebrew `version` is `1.0.2`
# (Homebrew rejects the zero-padded form), so the release URL pins the tag
# explicitly instead of interpolating `#{version}`.
#
# Only the two published release platforms are wired up: macOS arm64 (Apple
# Silicon) and Linux x86_64. There is no macOS Intel or Linux arm64 tarball in
# the v1.0.002 release, so `brew install` on those platforms is unsupported.
class Osagent < Formula
  desc "Signal Theory-optimized AI agent - your OS, supercharged"
  homepage "https://github.com/Miosa-osa/OSA"
  version "1.0.2"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/Miosa-osa/OSA/releases/download/v1.0.002/osa-macos-arm64.tar.gz"
      sha256 "9c7dc79a03a350c3bb93ce9fdffad8f44a80bbe0f1e42112968e42f54b0f12c3"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/Miosa-osa/OSA/releases/download/v1.0.002/osa-linux-x64.tar.gz"
      sha256 "ec631d24326f2f0d0e118abaf3aa86a89c95226e05cd95a8914a503e4969e825"
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
