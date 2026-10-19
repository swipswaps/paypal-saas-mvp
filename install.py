"""Interactive installer for Docker or Proxmox/LXC targets.
Uses subprocess.Popen exclusively (no subprocess.run).
"""
import os, sys, shutil, subprocess

def run(cmd, cwd=None, shell=False):
    print(f"[install] $ {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    p = subprocess.Popen(
        cmd, cwd=cwd, shell=shell,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    out, _ = p.communicate()
    if out:
        print(out.rstrip())
    if p.returncode != 0:
        print(f"[install] command failed with code {p.returncode}", file=sys.stderr)
    return p.returncode

def check_python():
    if sys.version_info < (3, 10):
        print("[install] Python >= 3.10 required.", file=sys.stderr)
        return False
    return True

def install_venv():
    if not os.path.isdir(".venv"):
        print("[install] creating virtual environment .venv")
        if run([sys.executable, "-m", "venv", ".venv"]) != 0:
            return False
    pip = os.path.join(".venv", "bin", "pip")
    if not os.path.exists(pip):
        pip = os.path.join(".venv", "Scripts", "pip.exe")
    return run([pip, "install", "--upgrade", "pip"]) == 0 and \
           run([pip, "install", "flask", "paypal-server-sdk", "python-dotenv",
                "requests", "Werkzeug", "cryptography"]) == 0

def install_docker():
    if not shutil.which("docker"):
        print("[install] docker not found. Install Docker: https://docs.docker.com/get-docker/", file=sys.stderr)
        return False
    return run(["docker", "compose", "up", "--build", "-d"]) == 0

def proxmox_instructions():
    print("""
[install] Proxmox VE / LXC target selected.
Official docs:
  https://pve.proxmox.com/wiki/Linux_Container
  https://pve.proxmox.com/pve-docs/chapter-pct.html

Suggested LXC workflow (run on the Proxmox host):
  pveam update
  pveam available | grep debian-12
  pveam download local debian-12-standard_12.7-1_amd64.tar.zst
  pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \\
      --hostname paypal-saas --memory 1024 --cores 2 --swap 512 \\
      --rootfs local-lvm:8 --password 'CHANGE_ME' \\
      --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1
  pct start 200
  pct exec 200 -- bash -c "apt update && apt install -y python3 python3-venv git"
  pct exec 200 -- bash -c "git clone <repo-url> /opt/paypal-saas && cd /opt/paypal-saas && python3 -m venv .venv && .venv/bin/pip install flask paypal-server-sdk python-dotenv requests Werkzeug cryptography"
Then configure .env and run: .venv/bin/python app.py
""")
    return True

def main():
    if not check_python():
        sys.exit(2)
    print("Select deployment target:")
    print("  [1] Docker / Docker Compose (recommended)")
    print("  [2] Proxmox VE / LXC")
    choice = input("Choice [1/2]: ").strip() or "1"
    if choice == "1":
        ok = install_docker()
    elif choice == "2":
        ok = install_venv() and proxmox_instructions()
    else:
        print("[install] invalid choice", file=sys.stderr)
        ok = False
    sys.exit(0 if ok else 2)

if __name__ == "__main__":
    main()
