cask "costbar" do
  version :latest
  sha256 :no_check

  url "https://github.com/uzaaft/costbar/releases/download/tip/Costbar.zip",
      verified: "github.com/uzaaft/costbar/"
  name "Costbar"
  desc "Menu-bar dashboard for developer infrastructure and AI subscription costs"
  homepage "https://github.com/uzaaft/costbar"

  # Costbar ships a rolling tip build rather than tagged versions, so there is
  # no version for Homebrew to compare against. `brew upgrade --cask --greedy`
  # reinstalls from the current tip; a plain `brew upgrade` will not.
  livecheck do
    skip "Rolling tip release"
  end

  depends_on macos: :sonoma

  app "Costbar.app"

  uninstall quit: "com.costbar.app"

  # Provider credentials live in the login Keychain and are deliberately left
  # alone: `brew uninstall` should not destroy tokens the user pasted in, and
  # reinstalling finds them again. `--zap` removes the rest. The Claude quota
  # bridge's entry in ~/.claude/settings.json is not ours to edit, so restore
  # it from Costbar's settings before uninstalling if it is installed.
  zap trash: [
    "~/Library/Application Support/Costbar",
    "~/Library/Caches/Costbar",
    "~/Library/Preferences/com.costbar.app.plist",
  ]
end
