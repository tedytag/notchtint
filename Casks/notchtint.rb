# Homebrew cask template. After the first GitHub release:
#   1. replace YOURNAME and update the version
#   2. run: shasum -a 256 NotchTint.zip  → paste into sha256
#   3. host in a tap repo (github.com/YOURNAME/homebrew-tap) under Casks/
# Users then install with:  brew install --cask YOURNAME/tap/notchtint
cask "notchtint" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_ZIP"

  url "https://github.com/YOURNAME/notchtint/releases/download/v#{version}/NotchTint.zip"
  name "NotchTint"
  desc "Paints the menu-bar area around the MacBook notch with the app's top-edge color"
  homepage "https://github.com/YOURNAME/notchtint"

  depends_on macos: ">= :sonoma"

  app "NotchTint.app"
end
