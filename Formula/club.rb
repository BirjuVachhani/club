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
  version "0.8.0"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-arm64.tar.gz"
      sha256 "e256b46d2a11e849ede9bd5b8b48737f79a85bb577aa026a58f1efd6ae9c9bee"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-macos-x64.tar.gz"
      sha256 "bddf19453ef90b91ad724451753b7f42b28df4ef422a457757c361b8bd033824"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-arm64.tar.gz"
      sha256 "e852fe73dca07ca90596580879b5ea05d524f6973f6fa96549bf288bc5f3b538"
    end
    on_intel do
      url "https://github.com/BirjuVachhani/club/releases/download/#{version}/club-cli-#{version}-linux-x64.tar.gz"
      sha256 "a6fe0236fe68fad9583942207fac65a1c9b00b4db3c5f9ba25d8a1bf1ce75825"
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
