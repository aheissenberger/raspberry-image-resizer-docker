class RpiImageResizer < Formula
  desc "Raspberry Pi image resize and partition adjuster (CLI)"
  homepage "https://github.com/aheissenberger/raspberry-image-resizer-docker"
  version "0.0.6"

  if Hardware::CPU.arm?
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.6/rpi-tool-darwin-arm64.tar.gz"
    sha256 "18207c14477268b70da615c5bf239f8dcc2866af1cc7421823dc981ed6350b76"
  else
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.6/rpi-tool-darwin-amd64.tar.gz"
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
