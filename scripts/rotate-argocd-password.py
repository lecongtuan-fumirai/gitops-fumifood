#!/usr/bin/env python3
"""
Securely rotate Argo CD admin password.
- Generates a cryptographically strong 32-character password.
- Hashes it using bcrypt (rounds 10).
- Updates secret argocd-secret (admin.password and admin.passwordMtime).
- Saves the plaintext password ONLY to /root/.argocd-admin-password (mode 0600).
- Restarts deployment/argocd-server.
"""
import os
import secrets
import string
import datetime
import subprocess
import base64
import bcrypt

def generate_password(length=32):
    alphabet = string.ascii_letters + string.digits + "!@#%^&*()-_=+"
    return ''.join(secrets.choice(alphabet) for _ in range(length))

def main():
    new_password = generate_password()
    salt = bcrypt.gensalt(rounds=10)
    hashed = bcrypt.hashpw(new_password.encode('utf-8'), salt).decode('utf-8')
    mtime = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Save to /root/.argocd-admin-password with 0600
    out_file = "/root/.argocd-admin-password"
    with open(out_file, "w") as f:
        f.write(new_password + "\n")
    os.chmod(out_file, 0o600)
    print(f"Saved new password to {out_file} (mode 0600)")

    # Update secret in k8s
    # base64 encode
    b64_pw = base64.b64encode(hashed.encode('utf-8')).decode('utf-8')
    b64_mtime = base64.b64encode(mtime.encode('utf-8')).decode('utf-8')

    patch = f'{{"data":{{"admin.password":"{b64_pw}","admin.passwordMtime":"{b64_mtime}"}}}}'
    res = subprocess.run([
        "kubectl", "-n", "argocd", "patch", "secret", "argocd-secret",
        "-p", patch
    ], capture_output=True, text=True, check=True)
    print("Patched argocd-secret:", res.stdout.strip())

    # Delete argocd-initial-admin-secret if present
    subprocess.run([
        "kubectl", "-n", "argocd", "delete", "secret", "argocd-initial-admin-secret",
        "--ignore-not-found=true"
    ], check=True)

    # Rollout restart argocd-server
    print("Restarting argocd-server...")
    subprocess.run([
        "kubectl", "-n", "argocd", "rollout", "restart", "deployment", "argocd-server"
    ], check=True)
    subprocess.run([
        "kubectl", "-n", "argocd", "rollout", "status", "deployment", "argocd-server", "--timeout=120s"
    ], check=True)
    print("Argo CD admin password rotation complete.")

if __name__ == "__main__":
    main()
