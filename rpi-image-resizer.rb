class RpiImageResizer < Formula
  desc "Raspberry Pi image resize and partition adjuster (CLI)"
  homepage "https://github.com/aheissenberger/raspberry-image-resizer-docker"
  version "0.0.25"

  if Hardware::CPU.arm?
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.25/rpi-tool-darwin-arm64.tar.gz"
    sha256 "803cfe88f95a4741f25ec545ec8873cbe688e2772c0249adc59c5967d9a4d229"
  else
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.25/rpi-tool-darwin-amd64.tar.gz"
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
