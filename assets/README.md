# assets

Loose source files that `build.sh` compiles at build time. Nothing here is a
build product — the `.car` asset catalog is generated during the `package`
stage (into the deployed `Emacs.app`), never committed.

## `icons/`

Loose [Icon Composer](https://developer.apple.com/icon-composer/) sources, one
`<name>.icon` directory per icon (`icon.json` + the loose image layers). When
`build.yml`'s `icon:` names one of these (e.g. `icon: dragon-plus` ↔
`icons/dragon-plus.icon`), `build.sh` runs `actool` on it to produce `Assets.car`
(the macOS 26 "Tahoe" app icon) plus an `.icns` for older macOS, and points
`Info.plist`'s `CFBundleIconName` at it. The directory basename **is** the icon
name. If no local `.icon` matches, `build.sh` falls back to resolving the icon
from the emacs-plus tap.

- **`dragon-plus.icon`** — the **"dragon-plus"** icon.

## Credits

The `dragon-plus.icon` icon is the **"dragon-plus"** icon from
[d12frosted/homebrew-emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus)
(`community/icons/dragon-plus`), redistributed here as its loose Icon Composer
source. All rights to the artwork remain with the original authors; see the
emacs-plus repository for licensing and attribution.

The build-time approach of compiling a loose `.icon` into `Assets.car` with
`actool` follows emacs-plus's
[`scripts/generate-tahoe-assets`](https://github.com/d12frosted/homebrew-emacs-plus/blob/master/scripts/generate-tahoe-assets).
