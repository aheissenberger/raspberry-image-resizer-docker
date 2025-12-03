class RpiImageResizer < Formula
  desc "Raspberry Pi image resize and partition adjuster (CLI)"
  homepage "https://github.com/aheissenberger/raspberry-image-resizer-docker"
  version "0.0.26"

  if Hardware::CPU.arm?
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.26/rpi-tool-darwin-arm64.tar.gz"
    sha256 "56ca034b2f769583b0025de0b96e4078759679243c100b2d4308a7cbb7621e99"
  else
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.26/rpi-tool-darwin-amd64.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  end

  def install
    bin.install "rpi-tool"
  end

  def caveats
    <<~EOS
      This tool requires either Docker Desktop or a Docker-compatible container runtime.
      
      Install Docker Desktop:
        brew install --cask docker
      
      Or use an existing Docker installation (including Docker Desktop, Colima, or Rancher Desktop).
      Verify Docker is available:
        docker --version
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/rpi-tool --version")
  end
end
