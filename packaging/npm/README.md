# @flavioacv/zelvo

Installer for [Zelvo](https://github.com/flavioacv/DevSweep), a macOS app for storage cleanup, developer workspaces and system monitoring.

```bash
npx @flavioacv/zelvo                  # install the latest release into /Applications and launch it
npx @flavioacv/zelvo --version 0.5.0  # install a specific version
npx @flavioacv/zelvo --to ~/Applications --no-open
```

The command downloads the release from GitHub, verifies it against the SHA-256 published with it, replaces any legacy `DevSweep.app` copy in the destination folder, and copies `Zelvo.app` into place. The app keeps itself updated afterwards via Sparkle.

macOS only. MIT licensed.
