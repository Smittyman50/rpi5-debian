#!/usr/bin/env python3
import os
import yaml
import ipaddress
from jinja2 import Environment, FileSystemLoader, StrictUndefined

TEMPLATES_DIR = "templates"
INVENTORY_FILE = "inventory/pis.yml"
OUT_BASE = "out/seeds"

env = Environment(
    loader=FileSystemLoader(TEMPLATES_DIR),
    autoescape=False,
    trim_blocks=True,
    lstrip_blocks=True,
    undefined=StrictUndefined,  # fail fast if a variable is missing/misspelled
)

t_user = env.get_template("user-data.j2")
t_meta = env.get_template("meta-data.j2")
t_net = env.get_template("network-config.j2")

with open(INVENTORY_FILE, "r", encoding="utf-8") as f:
    inv = yaml.safe_load(f) or {}

os.makedirs(OUT_BASE, exist_ok=True)

def netmask_from_prefix(cidr: str) -> str:
    """
    Accepts 'A.B.C.D/prefix' and returns dotted netmask.
    Example: '192.168.3.75/24' -> '255.255.255.0'
    """
    if "/" not in cidr:
        raise ValueError(f"Static net.address must be CIDR, got: {cidr!r}")
    prefix = int(cidr.split("/", 1)[1])
    return str(ipaddress.IPv4Network(f"0.0.0.0/{prefix}").netmask)

env.globals["netmask_from_prefix"] = netmask_from_prefix

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

    # Try local git (works when running in a checked-out repo)
    try:
        import subprocess
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

BUILD_SHA = get_build_id()
BUILD_SHA_SHORT = BUILD_SHA[:12]  # short but still highly unique

def normalize_net(cfg: dict) -> dict | None:
    net = cfg.get("net")
    if not net:
        return None

    net = dict(net)
    net.setdefault("mode", "dhcp")     # dhcp|static
    net.setdefault("ifname", "end0")
    net.setdefault("dhcp6", False)

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
        if "/" not in str(net.get("address", "")):
            raise ValueError(
                f"{cfg.get('hostname','<unknown>')}: net.address must be CIDR (e.g., 192.168.3.75/24)"
            )

    if "dns" in net and net["dns"] is not None and not isinstance(net["dns"], list):
        raise ValueError(f"{cfg.get('hostname','<unknown>')}: net.dns must be a list")
    if "search" in net and net["search"] is not None and not isinstance(net["search"], list):
        raise ValueError(f"{cfg.get('hostname','<unknown>')}: net.search must be a list")

    return net

pis = inv.get("pis", {}) or {}
for serial, cfg in pis.items():
    d = os.path.join(OUT_BASE, serial)
    os.makedirs(d, exist_ok=True)

    net = normalize_net(cfg)

    # Deterministic instance-id per build: serial + git SHA
    instance_id = f"{serial}-{BUILD_SHA_SHORT}"

    meta = t_meta.render(
        serial=serial,
        instance_id=instance_id,
        hostname=cfg["hostname"],
    )

    user = t_user.render(
        username=cfg.get("username", "smittyman"),
        passwd_hash=cfg.get("passwd_hash", ""),
        docker=bool(cfg.get("docker", False)),
        roles=cfg.get("roles", []) or [],
        ssh_authorized_keys=cfg.get("ssh_authorized_keys", []) or [],
        packages=cfg.get("packages", []) or [],
        timezone=cfg.get("timezone", "UTC"),
        net=net,  # keep if your template still references it (even though network is now in network-config)
    )

    network_cfg = None
    if net is not None:
        network_cfg = t_net.render(net=net)

    with open(os.path.join(d, "meta-data"), "w", encoding="utf-8") as f2:
        f2.write(meta.strip() + "\n")

    with open(os.path.join(d, "user-data"), "w", encoding="utf-8") as f2:
        f2.write(user.strip() + "\n")

    if network_cfg is not None:
        with open(os.path.join(d, "network-config"), "w", encoding="utf-8") as f2:
            f2.write(network_cfg.strip() + "\n")

    with open(os.path.join(d, "vendor-data"), "w", encoding="utf-8") as f2:
        f2.write("#cloud-config\n{}\n")

print(f"Rendered seeds to {OUT_BASE}/")
print(f"Build SHA: {BUILD_SHA} (short={BUILD_SHA_SHORT})")
