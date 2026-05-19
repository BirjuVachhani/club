# Homebrew formula for the club CLI.
#
# This repo doubles as a Homebrew tap. Because the repo is named `club`
# (not `homebrew-club`), users have to pass the clone URL explicitly —
# `brew tap user/name` only works for repos literally named
# `homebrew-<name>`.
#
#     brew tap birjuvachhani/club https://github.com/BirjuVachhani/club.git
#     brew install club
#
# (If we ever publish a dedicated `homebrew-club` repo mirroring just
# this Formula/ directory, the short form `brew install
# BirjuVachhani/club/club` would start working.)
#
# The formula pulls prebuilt binaries from the GitHub Release matching
# `version` below. When cutting a new release, bump `version` and update
# every sha256 from SHA256SUMS.txt on the release page.
class Club < Formula
  desc "Self-hosted, private Dart package repository CLI"
  homepage "https://github.com/BirjuVachhani/club"
  version "0.3.0"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-arm64.tar.gz"
      sha256 "693358b9d435c0a9acd6bc3ca722d55b6ea6a1d3990194d936801ab180919004"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-x64.tar.gz"
      sha256 "08de75af779efed3cd048c39ffa6c099346097413cc497180a685c60e92b229d"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-arm64.tar.gz"
      sha256 "84a9a2dee3f976d8b5737be8677c27b499677eaf69cffaf032daab15a27413ae"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-x64.tar.gz"
      sha256 "084a53e04057675d1d7b194fc21f1c58151c5822e21379c754c0852af9a2d177"
    end
  end

  # Keep the full `bundle` layout intact under libexec so the binary can
  # still resolve its sibling `lib/` via relative path — matches what
  # scripts/install.sh does.
  def install
    libexec.install "bin"
    libexec.install "lib" if Dir.exist?("lib")
    bin.install_symlink libexec/"bin/club"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/club --version")
  end
end
