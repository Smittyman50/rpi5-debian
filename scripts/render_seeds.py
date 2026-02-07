#!/usr/bin/env python3
import os, yaml
from jinja2 import Environment, FileSystemLoader

env = Environment(loader=FileSystemLoader("templates"), autoescape=False)
t_user = env.get_template("user-data.j2")
t_meta = env.get_template("meta-data.j2")

with open("inventory/pis.yml","r",encoding="utf-8") as f:
    inv = yaml.safe_load(f)

out_base = "out/seeds"
os.makedirs(out_base, exist_ok=True)

for serial, cfg in inv.get("pis", {}).items():
    d = os.path.join(out_base, serial)
    os.makedirs(d, exist_ok=True)

    meta = t_meta.render(serial=serial, hostname=cfg["hostname"])
    user = t_user.render(
        username=cfg.get("username","smittyman"),
        ssh_authorized_keys=cfg.get("ssh_authorized_keys", []),
        packages=cfg.get("packages", []),
        timezone=cfg.get("timezone","UTC"),
    )

    with open(os.path.join(d,"meta-data"),"w",encoding="utf-8") as f2:
        f2.write(meta.strip()+"\n")
    with open(os.path.join(d,"user-data"),"w",encoding="utf-8") as f2:
        f2.write(user.strip()+"\n")

print("Rendered seeds to out/seeds/")
