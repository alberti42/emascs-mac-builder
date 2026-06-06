#!/usr/bin/env python3
"""Read build.yml for build.sh. One YAML-parsing site, called per subcommand.

Usage:
    build-config.py patches      <build.yml>   # TSV: kind\\tname\\tpath_or_url\\tsha256
    build-config.py icon         <build.yml>   # the `icon:` name (or empty), no newline
    build-config.py inject-path  <build.yml>   # exit 1 iff inject_path is explicitly false, else 0

Mirrors the inline Ruby it replaces. Requires PyYAML (provisioned by build.sh in a venv).
"""
import os
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("build-config: PyYAML not available (build.sh provisions it in a venv)")


def load(cfg_path):
    with open(cfg_path) as f:
        return yaml.safe_load(f) or {}


def is_local(url):
    # A url starting with / ./ ../ ~ is a local file; anything else is downloaded.
    return any(url.startswith(p) for p in ("/", "./", "../", "~"))


def cmd_patches(cfg, cfg_path):
    home = os.path.expanduser("~")
    cfgdir = os.path.dirname(cfg_path)
    for p in cfg.get("patches") or []:
        if not isinstance(p, dict):
            sys.exit(f"patch entry must be {{name: {{url, sha256}}}}: {p!r}")
        name = next(iter(p))
        spec = p[name] or {}
        if not (spec.get("url") and spec.get("sha256")):
            sys.exit(f"patch {name}: url+sha256 required")
        url = spec["url"]
        if is_local(url):
            exp = home + url[1:] if url.startswith("~") else url
            if not exp.startswith("/"):
                exp = os.path.abspath(os.path.join(cfgdir, exp))
            print("\t".join(("local", name, exp, spec["sha256"])))
        else:
            print("\t".join(("external", name, url, spec["sha256"])))


def cmd_icon(cfg, cfg_path):
    icon = cfg.get("icon")
    sys.stdout.write(icon if isinstance(icon, str) else "")


def cmd_inject_path(cfg, cfg_path):
    # Exit 1 only when the key is present AND explicitly the boolean false.
    sys.exit(1 if cfg.get("inject_path") is False else 0)


COMMANDS = {"patches": cmd_patches, "icon": cmd_icon, "inject-path": cmd_inject_path}


def main(argv):
    if len(argv) != 3 or argv[1] not in COMMANDS:
        sys.exit(f"usage: build-config.py {{{'|'.join(COMMANDS)}}} <build.yml>")
    cmd, cfg_path = argv[1], argv[2]
    COMMANDS[cmd](load(cfg_path), cfg_path)


if __name__ == "__main__":
    main(sys.argv)
