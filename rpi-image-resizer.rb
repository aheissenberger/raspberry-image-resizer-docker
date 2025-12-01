class RpiImageResizer < Formula
  desc "Raspberry Pi image resize and partition adjuster (CLI)"
  homepage "https://github.com/aheissenberger/raspberry-image-resizer-docker"
  version "0.0.3"

  if Hardware::CPU.arm?
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.3/rpi-tool-darwin-arm64.tar.gz"
    sha256 "11cc2c3e3b83935fac8045fd613a4e36161c98d514f6cecdd00607d546dcaf3c"
  else
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.3/rpi-tool-darwin-amd64.tar.gz"
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
