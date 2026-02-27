class Osagent < Formula
  desc "Signal Theory-optimized AI agent - your OS, supercharged"
  homepage "https://github.com/Miosa-osa/OSA"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER"
    end
    on_intel do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-darwin-amd64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-linux-arm64.tar.gz"
      sha256 "PLACEHOLDER"
    end
    on_intel do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-linux-amd64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/osagent"
  end

  test do
    assert_match "osagent v", shell_output("#{bin}/osagent version")
  end
end
