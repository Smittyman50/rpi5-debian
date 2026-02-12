#!/usr/bin/env python3
import os
import yaml
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

with open(INVENTORY_FILE, "r", encoding="utf-8") as f:
    inv = yaml.safe_load(f) or {}

os.makedirs(OUT_BASE, exist_ok=True)

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
        raise ValueError(f"{cfg.get('hostname','<unknown>')}: net.mode must be dhcp|static (got {mode!r})")

    if mode == "static":
        missing = [k for k in ("address", "gateway") if not net.get(k)]
        if missing:
            raise ValueError(f"{cfg.get('hostname','<unknown>')}: missing net.{', net.'.join(missing)} for static config")

net = normalize_net(cfg)

pis = inv.get("pis", {}) or {}
for serial, cfg in pis.items():
    d = os.path.join(OUT_BASE, serial)
    os.makedirs(d, exist_ok=True)

    # Render meta-data
    meta = t_meta.render(
        serial=serial,
        hostname=cfg["hostname"],
    )

    # Render user-data
    user = t_user.render(
        username=cfg.get("username", "smittyman"),
        passwd_hash=cfg.get("passwd_hash", ""),
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
        f2.write("# empty vendor-data\n")

print(f"Rendered seeds to {OUT_BASE}/")
