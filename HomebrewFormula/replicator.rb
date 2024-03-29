# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class Replicator < Formula
  desc ""
  homepage ""
  version "0.14.0"

  on_macos do
    url "https://github.com/pivotal-cf/replicator/releases/download/0.14.0/replicator-darwin.tar.gz"
    sha256 "a29dcc59f339d3989e46d8b63d0d7f3832569770a40ca235d718a1d422f0bfaf"

    def install
      bin.install "replicator"
    end

    if Hardware::CPU.arm?
      def caveats
        <<~EOS
          The darwin_arm64 architecture is not supported for the Replicator
          formula at this time. The darwin_amd64 binary may work in compatibility
          mode, but it might not be fully supported.
        EOS
      end
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/pivotal-cf/replicator/releases/download/0.14.0/replicator-linux.tar.gz"
      sha256 "4f8ec1f2e5ba6ec79f61501b7cf0d107ca1c1aa9f833e245b48f672664d2582a"

      def install
        bin.install "replicator"
      end
    end
  end

  test do
    system "#{bin}/replicator --version"
  end
end
