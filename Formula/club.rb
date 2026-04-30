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
      sha256 "a2845cf0d4c141377bf4575a402540524d6b3745dc72618473828264241bdfe8"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-x64.tar.gz"
      sha256 "58d90ea908832546bc97ca3bedcca59ccf089c7cbf3b5a7a18cce3c7a62092b2"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-arm64.tar.gz"
      sha256 "8439950c70941a46f71b344fddbf6d4a13a843fd372f3ceea41427958fe46f23"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-x64.tar.gz"
      sha256 "b424bd00648269c56b82195fa5fe657a325b37c01ef27af294498eeb3a047918"
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
