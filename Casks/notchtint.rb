# Homebrew cask template. After the first GitHub release:
#   1. replace tedytag and update the version
#   2. run: shasum -a 256 NotchTint.zip  → paste into sha256
#   3. host in a tap repo (github.com/tedytag/homebrew-tap) under Casks/
# Users then install with:  brew install --cask tedytag/tap/notchtint
cask "notchtint" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_ZIP"

  url "https://github.com/tedytag/notchtint/releases/download/v#{version}/NotchTint.zip"
  name "NotchTint"
  desc "Paints the menu-bar area around the MacBook notch with the app's top-edge color"
  homepage "https://github.com/tedytag/notchtint"

  depends_on macos: ">= :sonoma"

  app "NotchTint.app"
end
