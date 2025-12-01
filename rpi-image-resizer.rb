class RpiImageResizer < Formula
  desc "Raspberry Pi image resize and partition adjuster (CLI)"
  homepage "https://github.com/aheissenberger/raspberry-image-resizer-docker"
  version "0.0.11"

  if Hardware::CPU.arm?
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.11/rpi-tool-darwin-arm64.tar.gz"
    sha256 "c47d579411a05e9642cea87bc5391c6ab96c53cf41e95b683011ccf2e767999a"
  else
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.11/rpi-tool-darwin-amd64.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  end

  depends_on "docker" => :recommended

  def install
    bin.install "rpi-tool"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/rpi-tool --version")
  end
end
