import os, sys, shutil, subprocess
def run(cmd, cwd=None, shell=False):
    print(f"[install] $ {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    p = subprocess.Popen(cmd, cwd=cwd, shell=shell,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out, _ = p.communicate()
    if out: print(out.rstrip())
    if p.returncode != 0:
        print(f"[install] command failed with code {p.returncode}", file=sys.stderr)
    return p.returncode
def main():
    if sys.version_info < (3, 10):
        print("[install] Python >= 3.10 required.", file=sys.stderr); sys.exit(2)
    print("Select deployment target:\n  [1] Docker (recommended)\n  [2] Proxmox VE / LXC")
    choice = input("Choice [1/2]: ").strip() or "1"
    if choice == "1":
        if not shutil.which("docker"):
            print("[install] docker not found. https://docs.docker.com/get-docker/", file=sys.stderr); sys.exit(2)
        ok = run(["docker", "compose", "up", "--build", "-d"]) == 0
    elif choice == "2":
        if not os.path.isdir(".venv"):
            if run([sys.executable, "-m", "venv", ".venv"]) != 0: sys.exit(2)
        pip = os.path.join(".venv", "bin", "pip")
        if not os.path.exists(pip): pip = os.path.join(".venv", "Scripts", "pip.exe")
        ok = run([pip, "install", "--upgrade", "pip"]) == 0 and \
             run([pip, "install", "flask", "paypal-server-sdk", "python-dotenv",
                  "requests", "Werkzeug", "cryptography"]) == 0
        print("\nProxmox LXC docs: https://pve.proxmox.com/wiki/Linux_Container")
        print("Then run: .venv/bin/python app.py")
    else:
        print("[install] invalid choice", file=sys.stderr); sys.exit(2)
    sys.exit(0 if ok else 2)
if __name__ == "__main__": main()
