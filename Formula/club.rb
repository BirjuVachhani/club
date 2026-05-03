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
  version "0.1.0"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-arm64.tar.gz"
      sha256 "c4c1964dbf81f1b09ce3774a1c0beb8c751c22b88dee634414f80e225a5f1474"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-x64.tar.gz"
      sha256 "a89cee943c9b3d1451caacd8571f729a3e5bdb056d0593c668646a328ea918de"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-arm64.tar.gz"
      sha256 "d42446031ae875fbe412cb6c305d5acb770877123057a1b1badd5f19de7c263d"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-x64.tar.gz"
      sha256 "787d3e0907b74355877d871728e54782ae2fd7fd9d827c100f9f45cc757035c4"
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
