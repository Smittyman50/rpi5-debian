#!/usr/bin/env python3
import os
import subprocess
import yaml

from pathlib import Path
from jinja2 import Environment, FileSystemLoader, StrictUndefined

TEMPLATES_DIR = "templates"
INVENTORY_FILE = "inventory/pis.yml"
OUT_BASE = "out/seeds"

# Base directory for resolving "lookup('file', ...)" paths
# Uses repo root (cwd) by default; override with LOOKUP_BASE_DIR if desired.
LOOKUP_BASE_DIR = Path(os.environ.get("LOOKUP_BASE_DIR", ".")).resolve()

def lookup(kind: str, path: str) -> str:
    """
    Minimal Ansible-like lookup() for plain Jinja2.

    Supports:
      - lookup('file', 'relative/or/absolute/path')

    Behavior:
      - Relative paths resolve against LOOKUP_BASE_DIR (default: repo root / cwd)
      - Returns UTF-8 text with a trailing newline (like Ansible file lookup tends to be used)
      - Raises FileNotFoundError / ValueError on errors (fails fast with StrictUndefined elsewhere)
    """
    if kind != "file":
        raise ValueError(f"lookup(kind={kind!r}) unsupported; only 'file' is implemented")

    p = Path(path)
    if not p.is_absolute():
        p = (LOOKUP_BASE_DIR / p).resolve()

    if not p.exists() or not p.is_file():
        raise FileNotFoundError(f"lookup('file', {path!r}) not found: {p}")

    # Preserve contents exactly, but ensure trailing newline so YAML block scalars behave nicely.
    text = p.read_text(encoding="utf-8")
    if not text.endswith("\n"):
        text += "\n"
    return text

env = Environment(
    loader=FileSystemLoader(TEMPLATES_DIR),
    autoescape=False,
    trim_blocks=True,
    lstrip_blocks=True,
    undefined=StrictUndefined,  # fail fast if a variable is missing/misspelled
)

# Register lookup() as a global so templates can call: {{ lookup('file', '...') }}
env.globals["lookup"] = lookup

t_user = env.get_template("user-data.j2")
t_meta = env.get_template("meta-data.j2")

def get_build_id() -> str:
    """
    Derive a deterministic build id from the Git SHA.
    Priority:
      1) CI env vars (Gitea/GitHub)
      2) git rev-parse (if .git present)
      3) fallback constant
    """
    for k in ("GITEA_SHA", "GITHUB_SHA", "CI_COMMIT_SHA"):
        v = os.environ.get(k, "").strip()
        if v:
            return v

    try:
        sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if sha:
            return sha
    except Exception:
        pass

    return "nogit"

def normalize_net(cfg: dict) -> dict | None:
    """
    Normalize cfg['net'] into a dict cloud-init can consume consistently.

    Inventory supports:
      net:
        mode: dhcp|static   (default: dhcp)
        ifname: end0        (default: end0)
        address: 192.168.3.50/24   (required for static)
        gateway: 192.168.3.1       (required for static)
        dns: [192.168.3.26, 1.1.1.1]   (optional)
        search: [home.arpa]            (optional)

    If mode=static and address is missing a CIDR prefix, default to /24.
    """
    net = cfg.get("net")
    if not net:
        return None

    net = dict(net)
    net.setdefault("mode", "dhcp")
    net.setdefault("ifname", "end0")

    mode = net.get("mode")
    if mode not in ("dhcp", "static"):
        raise ValueError(
            f"{cfg.get('hostname','<unknown>')}: net.mode must be dhcp|static (got {mode!r})"
        )

    if mode == "static":
        missing = [k for k in ("address", "gateway") if not net.get(k)]
        if missing:
            raise ValueError(
                f"{cfg.get('hostname','<unknown>')}: missing net.{', net.'.join(missing)} for static config"
            )

        # Ensure CIDR form: 192.168.3.50/24
        addr = str(net["address"]).strip()
        if "/" not in addr:
            net["address"] = f"{addr}/24"

        # Normalize dns/search to lists if provided as scalars
        if "dns" in net and net["dns"] is not None:
            if isinstance(net["dns"], str):
                net["dns"] = [net["dns"]]
            elif not isinstance(net["dns"], list):
                raise ValueError(
                    f"{cfg.get('hostname','<unknown>')}: net.dns must be a list or string"
                )

        if "search" in net and net["search"] is not None:
            if isinstance(net["search"], str):
                net["search"] = [net["search"]]
            elif not isinstance(net["search"], list):
                raise ValueError(
                    f"{cfg.get('hostname','<unknown>')}: net.search must be a list or string"
                )

    return net

def main() -> int:
    passwd_hash = os.environ.get("PI_PASSWD_HASH", "").strip()

    if not passwd_hash:
        raise ValueError("PI_PASSWD_HASH environment variable is required")

    with open(INVENTORY_FILE, "r", encoding="utf-8") as f:
        inv = yaml.safe_load(f) or {}

    os.makedirs(OUT_BASE, exist_ok=True)

    build_sha = get_build_id()
    build_sha_short = build_sha[:12]

    pis = inv.get("pis", {}) or {}
    if not isinstance(pis, dict) or not pis:
        raise ValueError("inventory/pis.yml must contain a top-level 'pis:' mapping")

    for serial, cfg in pis.items():
        if not isinstance(cfg, dict):
            raise ValueError(f"{serial}: inventory entry must be a mapping")

        if "hostname" not in cfg or not cfg["hostname"]:
            raise ValueError(f"{serial}: missing required key 'hostname'")

        d = os.path.join(OUT_BASE, serial)
        os.makedirs(d, exist_ok=True)

        net = normalize_net(cfg)

        # Deterministic instance-id per build: serial + git SHA
        instance_id = f"{serial}-{build_sha_short}"

        meta = t_meta.render(
            serial=serial,
            instance_id=instance_id,
            hostname=cfg["hostname"],
        )

        user = t_user.render(
            # make hostname available to user-data.j2 if you want to set it there too
            hostname=cfg["hostname"],
            username=cfg.get("username", "smittyman"),
            passwd_hash=passwd_hash,
            docker=bool(cfg.get("docker", False)),
            roles=cfg.get("roles", []) or [],
            ssh_authorized_keys=cfg.get("ssh_authorized_keys", []) or [],
            packages=cfg.get("packages", []) or [],
            timezone=cfg.get("timezone", "UTC"),
            net=net,
        )

        with open(os.path.join(d, "meta-data"), "w", encoding="utf-8") as f2:
            f2.write(meta.strip() + "\n")

        with open(os.path.join(d, "user-data"), "w", encoding="utf-8") as f2:
            f2.write(user.strip() + "\n")

        with open(os.path.join(d, "vendor-data"), "w", encoding="utf-8") as f2:
            f2.write("#cloud-config\n{}\n")

    print(f"Rendered seeds to {OUT_BASE}/")
    print(f"Build SHA: {build_sha} (short={build_sha_short})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
