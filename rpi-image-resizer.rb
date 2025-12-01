class RpiImageResizer < Formula
  desc "Cross-platform Raspberry Pi image resizing and SD card cloning tool"
  homepage "https://github.com/aheissenberger/raspberry-image-resizer-docker"
  version "0.0.1"
  
  # Update these URLs when creating a GitHub release
  if Hardware::CPU.arm?
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.1/rpi-tool-darwin-arm64.tar.gz"
    sha256 "" # Add SHA256 checksum after building release
  else
    url "https://github.com/aheissenberger/raspberry-image-resizer-docker/releases/download/v0.0.1/rpi-tool-darwin-amd64.tar.gz"
    sha256 "" # Add SHA256 checksum after building release
  end

  depends_on "docker"

  def install
    bin.install "rpi-tool"
  end

  def caveats
    <<~EOS
      rpi-image-resizer requires Docker Desktop to be installed and running.
      
      Install Docker Desktop from: https://www.docker.com/products/docker-desktop

      On first run, the tool will automatically build its Docker image (~2 minutes).

      Usage examples:
        # Clone SD card to image
        rpi-tool clone raspios-backup.img

        # Resize boot partition
        rpi-tool resize raspios.img --boot-size 512

        # Write image to SD card
        rpi-tool write raspios.img

      For more information:
        rpi-tool --help
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/rpi-tool --version")
  end
end
