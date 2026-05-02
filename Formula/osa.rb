class Osa < Formula
  desc "Signal Theory-optimized AI agent - your OS, supercharged"
  homepage "https://github.com/Miosa-osa/OSA"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-darwin-arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-darwin-amd64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-linux-arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/Miosa-osa/OSA/releases/download/v#{version}/osagent-#{version}-linux-amd64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  conflicts_with "osagent", because: "both formulas install the OSA command-line tools"
  conflicts_with "miosa", because: "both formulas install the OSA command-line tools"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/osagent" => "osa"
    bin.install_symlink libexec/"bin/osagent" => "osagent"
    bin.install_symlink libexec/"bin/osagent" => "miosa"
  end

  def caveats
    <<~EOS
      OSA installed the following commands:
        osa
        osagent
        miosa
    EOS
  end

  test do
    assert_match "osagent v", shell_output("#{bin}/osa version")
    assert_match "osagent v", shell_output("#{bin}/osagent version")
    assert_match "osagent v", shell_output("#{bin}/miosa version")
  end
end
