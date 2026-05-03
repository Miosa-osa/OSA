class Miosa < Formula
  desc "CLI entrypoint for the Optimal System Agent"
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

  conflicts_with "osa", because: "both formulas install the OSA command-line tools"
  conflicts_with "osagent", because: "both formulas install the OSA command-line tools"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/osagent" => "miosa"
    bin.install_symlink libexec/"bin/osagent" => "osa"
    bin.install_symlink libexec/"bin/osagent" => "osagent"
  end

  def caveats
    <<~EOS
      MIOSA installed the following commands:
        miosa
        osa
        osagent
    EOS
  end

  test do
    assert_match "osagent v", shell_output("#{bin}/miosa version")
    assert_match "osagent v", shell_output("#{bin}/osa version")
    assert_match "osagent v", shell_output("#{bin}/osagent version")
  end
end
