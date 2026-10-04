#!/usr/bin/env python3
"""Convert a dotenv file into a Kubernetes Secret manifest (stringData), dropping build/compose-only keys.

Usage: env2secret.py <env-file> <secret-name> <namespace> > out.enc.yaml  (then: sops -e -i out.enc.yaml)
Later duplicate keys override earlier ones (docker compose semantics).
"""
import sys

DROP = {"DOCKERHUB_USERNAME", "IMAGE_TAG", "FRONTEND_PORT", "NODE_ENV", "PORT",
        "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"}
DROP_PREFIXES = ("VITE_",)

env_file, name, namespace = sys.argv[1:4]
values = {}
with open(env_file, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        if key in DROP or key.startswith(DROP_PREFIXES):
            continue
        values[key] = val


def q(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


print("apiVersion: v1")
print("kind: Secret")
print("metadata:")
print(f"  name: {name}")
print(f"  namespace: {namespace}")
print("type: Opaque")
print("stringData:")
for key in sorted(values):
    print(f"  {key}: {q(values[key])}")
