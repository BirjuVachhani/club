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
      sha256 "9719ad72aeb1e9268a92d631c4efb6a945f4869beb38b338d88becf658393084"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-x64.tar.gz"
      sha256 "805972e3904a5bf21f57cd182e544f7d9f458fbc9f5bc5c0fe86688540992853"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-arm64.tar.gz"
      sha256 "03c58da7c3813c989cb420fc0cc9f2029aec2860f649831daebfb9746e5bc533"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-x64.tar.gz"
      sha256 "351e855e4ce6f2e93682d6244c3752dd2009a2f70d7fd8e182d8ea5390e733a5"
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
