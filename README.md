# emacs-mac-builder

A standalone Bash pipeline that builds a self-contained, natively-compiled
`Emacs.app` for macOS from a local Emacs git checkout.

It is inspired by — but fully independent of — the
[d12frosted/emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus)
project, and reads a `build.yml` in the same schema so icons and patch sets stay
interchangeable.

> **Status:** early. This README is intentionally minimal and will grow once the
> project settles.

## Usage

```sh
./build.sh            # full pipeline
./build.sh prepare    # export source + apply patches only
./build.sh configure  # ... through ./configure
./build.sh build      # ... through gmake (the long step)
./build.sh package    # install + icon + sign + deploy
```

Stages are cumulative and ordered; each runs every stage up to and including the
named one. See the comment header in [`build.sh`](build.sh) for the full list of
stages, environment variables, and configuration.

## License

[MIT](LICENSE) © Andrea Alberti
