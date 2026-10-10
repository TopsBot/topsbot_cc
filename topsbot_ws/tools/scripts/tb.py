#!/usr/bin/env python3
"""tb — topsbot_cc command CLI.

Argument parsing is declarative (argparse); help is generated automatically.
lunch / tb top stay in tools/scripts/envsetup.sh because they must modify the current shell;
m/mm detect the package of the current directory there and forward as -s.

Subcommands:
  update code|sysroot|docker-image|all
      ensure resources ready. code pulls latest (dirty repos are skipped with
      a warning); sysroot/docker-image refresh an existing resource only after
      a single confirmation (local changes are dropped).
  build [--all|-s PKG]   full build (default) or single package
  clean [--all|-s PKG]   clean full workspace (default) or one package
  package [list] [--all|-s PKG] [--refresh] [--distro DISTRO]
      bloom → debian source package (.dsc + tarballs) in topsbot_ws/debsrc/DISTRO/
      (DISTRO defaults to the lunched variant)
  shell --cross|--sysroot   fast cross-build & verification shell (cross env
      preloaded by tools/scripts/cross_env.sh), or a sysroot chroot
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))  # topsbot_ws/tools/scripts
TOOLS_DIR = os.path.dirname(SCRIPTS_DIR)  # topsbot_ws/tools
WS = os.path.dirname(TOOLS_DIR)  # topsbot_ws
CC_ROOT = os.path.dirname(WS)  # topsbot_cc
TARGET_DIR = os.path.join(WS, "configs", "target")
SRC = os.path.join(WS, "src")
REPOS_FILE = os.path.join(WS, "configs", "ros2.repos")
DOCKER_DIR = os.path.join(TOOLS_DIR, "docker")
_UBUNTU = {"jammy": "22.04", "noble": "24.04"}
CC_MOUNT = "/mnt/topsbot_cc"
DEPS_DIR = os.path.join(CC_ROOT, ".bloom", "deps")
EVENT_HANDLERS = "--event-handlers console_cohesion+ console_direct+"

_ACTIVE = []


# ---------------------------------------------------------------------------
# runners
# ---------------------------------------------------------------------------


def run(*cmd, **kw):
    print("+", " ".join(shlex.quote(c) for c in cmd))
    proc = subprocess.Popen(cmd, **kw)
    _ACTIVE.append(proc)
    try:
        return proc.wait()
    except KeyboardInterrupt:
        proc.kill()
        _stop_build_containers()
        raise
    finally:
        if proc.poll() is None:
            proc.kill()
            _stop_build_containers()


def _stop_build_containers():
    """Stop the persistent tb-build container (or remove the one-shot one).
    SIGINT is masked so a second ^C cannot abort the cleanup."""
    import signal as _signal

    name = tb_build_name()
    old = _signal.signal(_signal.SIGINT, _signal.SIG_IGN)
    try:
        if os.environ.get("TB_ONESHOT"):
            subprocess.call(
                ["docker", "rm", "-f", name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            subprocess.call(
                ["docker", "kill", name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    finally:
        _signal.signal(_signal.SIGINT, old)


def active_target(required=True):
    """Return the lunch-selected target (BUILD_TARGET). Strict: error if unset."""
    t = os.environ.get("BUILD_TARGET")
    if not t:
        if required:
            print("no target selected: run 'lunch' to pick one", file=sys.stderr)
        return None
    return t


def active_variant():
    return os.environ.get("BUILD_VARIANT") or ""


def board_dir(target):
    """Per-board config dir: configs/target/<board>/ (board JSON + files it
    references, e.g. sysroot package lists, live side by side)."""
    return os.path.join(TARGET_DIR, target)


def load_target(target):
    """Load <board>/<board>.json, deep-merged with <board>.override.json."""

    def deep_merge(base, over):
        out = dict(base)
        for k, v in over.items():
            if isinstance(v, dict) and isinstance(out.get(k), dict):
                out[k] = deep_merge(out[k], v)
            else:
                out[k] = v
        return out

    base_path = os.path.join(board_dir(target), f"{target}.json")
    with open(base_path) as f:
        cfg = json.load(f)
    over_path = os.path.join(board_dir(target), f"{target}.override.json")
    if os.path.isfile(over_path):
        with open(over_path) as f:
            cfg = deep_merge(cfg, json.load(f))
    return cfg


def resolve_cfg(cfg, variant=None):
    """Board JSON + active variant overlay (sysroot / distro)."""
    cfg = cfg or {}
    out = dict(cfg)
    variants = cfg.get("variants") if isinstance(cfg.get("variants"), dict) else {}
    v = variant if variant is not None else active_variant()
    if variants:
        if not v:
            v = cfg.get("default_variant") or next(iter(variants))
        vcfg = variants.get(v) or {}
        if not isinstance(vcfg, dict):
            vcfg = {}
        out["variant"] = v
        out["distro"] = vcfg.get("distro") or v
        if vcfg.get("image"):
            out["image"] = vcfg["image"]
        if vcfg.get("remote_image"):
            out["remote_image"] = vcfg["remote_image"]
        if vcfg.get("container"):
            out["container"] = vcfg["container"]
        sysroot = {**(cfg.get("sysroot") or {}), **(vcfg.get("sysroot") or {})}
        if sysroot:
            out["sysroot"] = sysroot
        return out
    out["variant"] = v or cfg.get("default_variant") or ""
    out["distro"] = cfg.get("distro") or out["variant"]
    out.setdefault("sysroot", cfg.get("sysroot") or {})
    return out


def load_active(required=True):
    """Merged board JSON with the lunched variant overlay. None if unset/invalid."""
    target = active_target(required=required)
    if not target:
        return None
    cfg = load_target(target)
    variants = cfg.get("variants")
    v = active_variant()
    if isinstance(variants, dict) and variants:
        if v and v not in variants:
            known = ", ".join(variants)
            print(
                f"unknown variant {v!r} for {target} (known: {known}); run 'lunch'",
                file=sys.stderr,
            )
            return None
        if not v:
            v = cfg.get("default_variant") or next(iter(variants))
    return resolve_cfg(cfg, variant=v or None)


def active_image():
    """JSON `image`, or auto `topsbot_riscv64_cross_build:{variant}`."""
    cfg = load_active(required=False) or {}
    if cfg.get("image"):
        return cfg["image"]
    v = cfg.get("variant") or active_variant() or "default"
    return f"topsbot_riscv64_cross_build:{v}"


def active_remote_image():
    cfg = load_active(required=False) or {}
    return cfg.get("remote_image") or ""


def tb_build_name():
    """JSON `container`, or auto `tb-build-{variant}`."""
    cfg = load_active(required=False) or {}
    if cfg.get("container"):
        return cfg["container"]
    v = cfg.get("variant") or active_variant() or "default"
    return f"tb-build-{v}"


def _sysroot_spec(cfg):
    """(url, dir) from JSON. dir auto `sysroot/{variant}` only when
    url is set and dir is not. Both empty if JSON specified neither."""
    sr = cfg.get("sysroot") or {}
    url = sr.get("url") or ""
    d = sr.get("dir") or ""
    if not d and url:
        d = f"sysroot/{cfg.get('variant') or 'default'}"
    return url, d


def sysroot_dir(cfg=None):
    """Absolute sysroot dir from the resolved variant config."""
    if cfg is None:
        cfg = load_active(required=True) or {}
    else:
        cfg = resolve_cfg(cfg)
    _, d = _sysroot_spec(cfg)
    if not d:
        print(
            "[sysroot] board JSON must set sysroot.url and/or sysroot.dir",
            file=sys.stderr,
        )
        sys.exit(1)
    return d if os.path.isabs(d) else os.path.join(CC_ROOT, d)


def sysroot_rel(cfg=None):
    """Sysroot path relative to CC_ROOT (for container_rm). None if outside."""
    if cfg is None:
        cfg = load_active(required=False) or {}
    else:
        cfg = resolve_cfg(cfg)
    _, d = _sysroot_spec(cfg)
    if not d:
        return None
    if os.path.isabs(d):
        rel = os.path.relpath(d, CC_ROOT)
        if rel.startswith(".."):
            return None
        return rel
    return d


# ---------------------------------------------------------------------------
# sysroot packages (sysroot.packages -> list file next to the board JSON)
# ---------------------------------------------------------------------------


def sysroot_pkg_list(cfg):
    """Package names from the file referenced by sysroot.packages (relative
    to the board dir). Entries are assumed to be valid apt package names."""
    ref = (cfg.get("sysroot") or {}).get("packages") or ""
    target = active_target(required=False)
    if not ref or not target:
        return []
    path = ref if os.path.isabs(ref) else os.path.join(board_dir(target), ref)
    if not os.path.isfile(path):
        print(f"[sysroot] package list not found: {path}", file=sys.stderr)
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                out.append(line)
    return out


def _sysroot_installed(sr):
    """Installed package names per the sysroot's own dpkg status."""
    status = os.path.join(sr, "var", "lib", "dpkg", "status")
    installed = set()
    if os.path.isfile(status):
        pkg = ok = None
        with open(status, errors="replace") as f:
            for line in f:
                if line.startswith("Package: "):
                    pkg = line[9:].strip()
                elif line.startswith("Status: "):
                    ok = line.strip() == "Status: install ok installed"
                elif line == "\n":
                    if pkg and ok:
                        installed.add(pkg)
                    pkg = ok = None
        if pkg and ok:
            installed.add(pkg)
    return installed


def _sysroot_unavailable(cfg):
    """Packages with no apt candidate for this distro/arch (negative cache
    written by _install_sysroot_packages so they are not retried)."""
    distro = cfg.get("distro") or cfg.get("variant") or ""
    path = os.path.join(
        CC_ROOT, "sysroot", "archives", f"apt-{distro}", "unavailable.list"
    )
    if not os.path.isfile(path):
        return set()
    with open(path) as f:
        return {line.strip() for line in f if line.strip()}


def _sysroot_missing(cfg, pkgs):
    """pkgs neither installed in the sysroot nor known to have no candidate."""
    installed = _sysroot_installed(sysroot_dir(cfg))
    unavail = _sysroot_unavailable(cfg)
    return [p for p in pkgs if p not in installed and p not in unavail]


def _ensure_sysroot_pkgs(cfg, pkgs, tag):
    """Single funnel for sysroot package injection (manual package.list and
    rosdep-resolved deps alike): report what's missing, fetch + unpack it."""
    missing = _sysroot_missing(cfg, pkgs)
    if not missing:
        return 0
    print(f"[{tag}] packages missing in sysroot: {' '.join(missing)}")
    return _install_sysroot_packages(cfg, missing)


def ensure_sysroot_packages(cfg):
    """Guarantee the sysroot exists and the packages named by
    sysroot.packages are present inside it; missing ones are fetched in the
    build container and unpacked. Readiness is checked first: the board's
    package list may legitimately be empty (mes20's is comments only), yet a
    missing sysroot must still be fetched — otherwise every build dies later
    in cross_env with "/sysroot/usr does not exist"."""
    if not _sysroot_ready(sysroot_dir(cfg)):
        rc = update_sysroot(cfg)
        if rc:
            return rc
    pkgs = sysroot_pkg_list(cfg)
    if not pkgs:
        return 0
    return _ensure_sysroot_pkgs(cfg, pkgs, "sysroot")


def _install_sysroot_packages(cfg, pkgs):
    """apt (isolated root seeded from the sysroot's own sources, sysroot
    dpkg status as state) resolves/downloads missing debs + deps into
    sysroot/archives/, then dpkg-deb -x into the sysroot; the sysroot dpkg
    status is updated so queries see them. Packages with no candidate are
    skipped and recorded in unavailable.list (negative cache)."""
    distro = cfg.get("distro") or cfg.get("variant") or ""
    if not distro:
        print("[sysroot] distro unknown; cannot fetch packages", file=sys.stderr)
        return 1
    arch = (cfg.get("env") or {}).get("TARGET_ARCH") or "riscv64"
    script = f"""
set -euo pipefail
SR=/sysroot
A={CC_MOUNT}/sysroot/archives/apt-{distro}
mkdir -p "$A/etc/apt/sources.list.d" "$A/etc/apt/keyrings" \\
  "$A/etc/apt/preferences.d" "$A/var/lib/apt/lists/partial" \\
  "$A/var/cache/apt/archives/partial" "$SR/var/lib/dpkg"
touch "$SR/var/lib/dpkg/status"
# Prefer the sysroot's own apt config (its mirror + the private
# tbros/taco-sdk/OBS repos); fall back to plain ubuntu-ports when the
# sysroot carries no sources of its own.
if [[ -s "$SR/etc/apt/sources.list" ]]; then
  cp "$SR/etc/apt/sources.list" "$A/etc/apt/sources.list"
else
  printf '%s\\n' \\
    "deb [arch={arch}] http://ports.ubuntu.com/ubuntu-ports {distro} main universe" \\
    "deb [arch={arch}] http://ports.ubuntu.com/ubuntu-ports {distro}-updates main universe" \\
    "deb [arch={arch}] http://ports.ubuntu.com/ubuntu-ports {distro}-security main universe" \\
    > "$A/etc/apt/sources.list"
fi
# Private repos in sources.list.d use signed-by keyrings; copy both and
# point signed-by at the copies (the originals are sysroot-absolute paths).
if compgen -G "$SR/etc/apt/sources.list.d/*.list" >/dev/null; then
  cp "$SR"/etc/apt/sources.list.d/*.list "$A/etc/apt/sources.list.d/"
fi
if compgen -G "$SR/etc/apt/sources.list.d/*.sources" >/dev/null; then
  cp "$SR"/etc/apt/sources.list.d/*.sources "$A/etc/apt/sources.list.d/"
fi
if compgen -G "$SR/etc/apt/keyrings/*.gpg" >/dev/null; then
  cp "$SR"/etc/apt/keyrings/*.gpg "$A/etc/apt/keyrings/"
  sed -i "s|/etc/apt/keyrings/|$A/etc/apt/keyrings/|g" \\
    "$A/etc/apt/sources.list.d"/*.list \\
    "$A/etc/apt/sources.list.d"/*.sources 2>/dev/null || true
fi
OPTS=(-o "Dir=$A" -o "APT::Architecture={arch}" \\
  -o "Dir::State::status=$SR/var/lib/dpkg/status" \\
  -o "Dir::Etc::Trusted=/usr/share/keyrings/ubuntu-archive-keyring.gpg" \\
  -o "APT::Sandbox::User=root")
echo "PROGRESS updating apt index" >&2
apt-get "${{OPTS[@]}}" update
# Drop packages with no candidate for the target arch (e.g. chromium-browser
# is snap-only on noble) and record them; otherwise one bad package fails the
# whole batch and every build retries it.
avail=()
unavail=()
for p in {' '.join(pkgs)}; do
  cand="$(apt-cache "${{OPTS[@]}}" policy "$p" | awk '/Candidate:/ {{print $2}}')"
  if [[ -z "$cand" || "$cand" == "(none)" ]]; then
    unavail+=("$p")
  else
    avail+=("$p")
  fi
done
if [[ ${{#unavail[@]}} -gt 0 ]]; then
  echo "[sysroot] WARNING: no installation candidate for {distro}/{arch} (skipped): ${{unavail[*]}}"
  printf '%s\\n' "${{unavail[@]}}" > "$A/unavailable.list"
else
  : > "$A/unavailable.list"
fi
if [[ ${{#avail[@]}} -eq 0 ]]; then
  echo "[sysroot] nothing to install"
  exit 0
fi
echo "PROGRESS downloading ${{#avail[@]}} packages (+dependencies)" >&2
apt-get "${{OPTS[@]}}" -y --download-only --no-install-recommends install \\
  "${{avail[@]}}"
python3 - "$SR" "$A/var/cache/apt/archives" <<'EOF'
import glob, os, re, shutil, subprocess, sys

sr, debs_dir = sys.argv[1], sys.argv[2]
status = os.path.join(sr, "var/lib/dpkg/status")

def record_spans(text):
    # (start, end, package) per RFC822 record; a span includes the blank
    # line(s) terminating the record, so the spans tile the file.
    out, off, start, pkg, in_rec = [], 0, 0, None, False
    for line in text.splitlines(keepends=True):
        if not line.strip():
            off += len(line)
            if in_rec:
                out.append((start, off, pkg))
                in_rec = False
            start = off
            continue
        if not in_rec:
            in_rec, start, pkg = True, off, None
        if pkg is None and line.startswith("Package: "):
            pkg = line[9:].strip()
        off += len(line)
    if in_rec:
        out.append((start, off, pkg))
    return out

def version_of(rec):
    m = re.search(r"^Version: (.*)$", rec, re.M)
    return m.group(1).strip() if m else "?"

with open(status, errors="replace") as f:
    text = f.read()

span = {{}}
for s, e, p in record_spans(text):
    if p and p not in span:
        span[p] = (s, e)

debs = sorted(glob.glob(os.path.join(debs_dir, "*.deb")))
edits, added = [], []
for i, deb in enumerate(debs, 1):
    ctl = subprocess.run(["dpkg-deb", "-f", deb], capture_output=True, text=True).stdout
    d = dict(l.split(": ", 1) for l in ctl.splitlines() if ": " in l)
    name = d.get("Package")
    # Register with the full control fields (Provides/Conflicts/Multi-Arch
    # matter to apt's solver) plus an installed Status line; cherry-picked
    # fields leave the status inconsistent and break later installs.
    record = ctl.rstrip("\\n") + "\\nStatus: install ok installed\\n\\n"
    # Extract with GNU tar --keep-directory-symlink instead of dpkg-deb -x:
    # plain tar semantics replace a /lib -> usr/lib symlink with a real
    # directory as soon as a deb ships a ./lib/ member, which de-merges the
    # sysroot and drops /lib/ld-linux-<arch>.so.1 (nothing can exec there after).
    try:
        subprocess.run(
            ["sh", "-c",
             'dpkg-deb --fsys-tarfile "$1" | tar -x --keep-directory-symlink -C "$2"',
             "sh", deb, sr],
            check=True)
    except subprocess.CalledProcessError:
        print("[sysroot] WARNING: tar --keep-directory-symlink unavailable/failed; "
              "falling back to dpkg-deb -x for %s" % deb, file=sys.stderr)
        subprocess.run(["dpkg-deb", "-x", deb, sr], check=True)
    print("PROGRESS unpacking %d/%d %s" % (i, len(debs), name or "?"), file=sys.stderr)
    if not name:
        continue
    if name in span:
        s, e = span[name]
        if text[s:e] == record:
            continue  # already registered verbatim: leave the file untouched
        # dpkg-deb -x overwrote the files, so the registered version has to
        # follow the deb: append-only registration is what drifts out of date
        # and then makes apt refuse every later install.
        edits.append((s, e, name, version_of(text[s:e]), d.get("Version", "?"), record))
    else:
        added.append((name, d.get("Version", "?"), record))

if edits:
    # Apply newest-first so the remaining offsets stay valid; every byte
    # outside the changed records is preserved verbatim.
    for s, e, name, old, new, record in sorted(edits, key=lambda x: x[0], reverse=True):
        text = text[:s] + record + text[e:]
        print("[sysroot] status updated %s %s -> %s" % (name, old, new), file=sys.stderr)
if added:
    if text and not text.endswith("\\n\\n"):
        text = text.rstrip("\\n") + "\\n\\n"
    text += "".join(r for _, _, r in added)
    for name, ver, _ in added:
        print("[sysroot] status added %s %s" % (name, ver), file=sys.stderr)
if edits or added:
    tmp = status + ".new"
    with open(tmp, "w") as f:
        f.write(text)
    shutil.copystat(status, tmp)  # keep the original mode/mtime; owner is root either way
    os.replace(tmp, status)
print("[sysroot] unpacked %d debs: %d new, %d status-updated" % (len(debs), len(added), len(edits)))
EOF
"""
    n = len(pkgs)
    rc, lines = run_spin(
        f"[sysroot] injecting {n} package{'s' if n != 1 else ''}",
        _exec_argv("bash", "-c", script),
    )
    for line in lines:
        if line.startswith("[sysroot]"):
            print(line, end="")
    return rc


def ensure_sysroot_deps(cfg):
    """Resolve package.xml dependencies with rosdep and inject the missing
    ones into the sysroot. deps.sh (in the container) keeps a content-hash
    stamp over all package.xml + the rosdep rules, so unchanged workspaces
    skip resolution entirely. The resolved list is always re-checked against
    the sysroot dpkg status, which covers a refreshed sysroot. Resolution
    failure (offline, no cache) only warns — the build proceeds and missing
    deps surface as compile errors instead."""
    distro = cfg.get("distro") or ""
    if not distro:
        return 0
    sr = sysroot_dir(cfg)
    if not _sysroot_ready(sr):
        return 0  # ensure_sysroot_packages is responsible for fetching it
    rc, lines = run_spin(
        "[deps] resolving dependencies",
        _exec_argv(
            "bash",
            f"{CC_MOUNT}/topsbot_ws/tools/scripts/deps.sh",
            "--distro",
            distro,
        ),
    )
    if rc:
        print(
            "[deps] rosdep resolution failed; continuing without dependency injection",
            file=sys.stderr,
        )
        return 0
    reran = False
    for line in lines:
        m = re.search(r"resolved (\d+) keys -> (\d+) apt packages", line)
        if m:
            reran = True
            print(f"[deps] resolved {m.group(1)} keys -> {m.group(2)} apt packages")
        elif line.startswith("[deps] WARNING") or line.startswith("    ERROR"):
            print(line, end="")
    if not reran:
        print("[deps] dependencies up to date")
    lst = os.path.join(DEPS_DIR, f"resolved-{distro}.list")
    pkgs = []
    if os.path.isfile(lst):
        with open(lst) as f:
            pkgs = [line.strip() for line in f if line.strip()]
    skipped = [
        p
        for p in pkgs
        if p in _sysroot_unavailable(cfg) and p not in _sysroot_installed(sr)
    ]
    if skipped and reran:
        # install-time skips are reported by _install_sysroot_packages itself
        arch = (cfg.get("env") or {}).get("TARGET_ARCH") or ""
        print(f"[deps] no {distro}/{arch} candidate, skipped: {' '.join(skipped)}")
    rc = _ensure_sysroot_pkgs(cfg, pkgs, "deps")
    if rc:
        # drop the resolution stamp so the next build re-resolves
        container_rm(os.path.relpath(os.path.join(DEPS_DIR, f"stamp-{distro}"), CC_ROOT))
    return rc


def build_container(*cmd):
    """Run *cmd in the build container; build.sh uses /sysroot (docker mount
    of sysroot.dir). Host relpath is wrong when dir is outside the repo."""
    return exec_cmd(
        "bash",
        *cmd,
        privileged=True,
        env={"TOPSBOT_SYSROOT_PATH": "/sysroot"},
    )


def container_rm(*paths):
    """Remove paths (relative to CC_ROOT) inside the container; host rm fails
    on root-owned build artifacts."""
    rm_cmd = "rm -rf " + " ".join(f"{CC_MOUNT}/{p}" for p in paths)
    return exec_cmd("bash", "-c", rm_cmd)


# ---------------------------------------------------------------------------
# persistent build container; TB_ONESHOT falls back to one-shot
# ---------------------------------------------------------------------------


def _tb_oneshot_name():
    import secrets

    return f"tb-build_{secrets.token_hex(3)}"


def _ensure_image():
    """Same as `tb update docker-image` so docker create does not Hub-pull."""
    rc = update_docker_image(load_active(required=False) or {})
    if rc:
        sys.exit(rc)


def _create_tb_build():
    _ensure_image()
    sr = sysroot_dir()
    name = tb_build_name()
    image = active_image()
    rc = run(
        "docker",
        "create",
        "--init",
        "--privileged",
        "-it",
        "-v",
        f"{CC_ROOT}:{CC_MOUNT}",
        "-v",
        f"{sr}/opt:/opt:ro",
        "-v",
        f"{sr}:/sysroot",
        "-w",
        f"{CC_MOUNT}/topsbot_ws",
        "--name",
        name,
        image,
        "bash",
        "-c",
        "tail -f /dev/null",
    )
    if rc:
        sys.exit(rc)
    rc = run("docker", "start", name)
    if rc:
        sys.exit(rc)


def ensure_tb_build():
    """Ensure the persistent container exists and is running. Recreates it if
    the mounted sysroot/opt or image differs from the current variant."""
    sr = sysroot_dir()
    name = tb_build_name()
    image = active_image()
    if (
        subprocess.call(
            ["docker", "inspect", name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        != 0
    ):
        _create_tb_build()
        return
    out = subprocess.run(
        [
            "docker",
            "inspect",
            name,
            "--format",
            "{{range .Mounts}}{{.Source}}|{{.Destination}}\n{{end}}",
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    mounted = [line.split("|") for line in out.stdout.splitlines() if "|" in line]
    want = [f"{sr}/opt", "/opt"]
    have_image = subprocess.run(
        ["docker", "inspect", name, "--format", "{{.Config.Image}}"],
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    rebuild = want not in mounted or have_image != image
    if rebuild:
        reason = "image" if have_image != image else "sysroot path"
        print(f"[tb] {reason} changed; rebuilding {name}")
        subprocess.call(
            ["docker", "rm", "-f", name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        _create_tb_build()
        return
    st = subprocess.run(
        ["docker", "inspect", name, "--format", "{{.State.Running}}"],
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    if st != "true":
        run("docker", "start", name)


def stop_tb_build():
    if not os.environ.get("TB_ONESHOT"):
        subprocess.call(
            ["docker", "stop", tb_build_name()],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


# The container runs as root while the bind-mounted workspace stays owned by
# the host user, so git (>= 2.35.2) rejects every repo with "detected dubious
# ownership" (exit 128) and any CMake that shells out to git fails with it
# (eProsima's eprosima_find_thirdparty calls `git submodule update`). Pass the
# exception through git's env config instead of editing host or in-container
# gitconfig; docker run/exec both honour these.
_GIT_SAFE_ENV = {
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "safe.directory",
    "GIT_CONFIG_VALUE_0": "*",
}


def _exec_argv(*cmd, privileged=False, env=None, interactive=False):
    """argv for *cmd in the build container (exec_cmd and run_spin share this).
    Persistent tb-build by default; TB_ONESHOT uses a throwaway container."""
    env_args = []
    for k, v in {**_GIT_SAFE_ENV, **(env or {})}.items():
        env_args += ["-e", f"{k}={v}"]
    it = ["-it"] if interactive else []
    if os.environ.get("TB_ONESHOT"):
        _ensure_image()
        argv = (
            ["docker", "run", "--rm", "--name", _tb_oneshot_name()]
            + it
            + [
                "-v",
                f"{CC_ROOT}:{CC_MOUNT}",
                "-v",
                f"{sysroot_dir()}/opt:/opt:ro",
                "-v",
                f"{sysroot_dir()}:/sysroot",
                "-w",
                f"{CC_MOUNT}/topsbot_ws",
            ]
        )
        if privileged:
            argv.append("--privileged")
        return argv + env_args + [active_image(), *cmd]
    ensure_tb_build()
    return ["docker", "exec", *it, *env_args, tb_build_name(), *cmd]


def exec_cmd(*cmd, privileged=False, env=None, interactive=False):
    """Run *cmd inside the build container, output passed through."""
    return run(
        *_exec_argv(*cmd, privileged=privileged, env=env, interactive=interactive)
    )


_SPIN_FRAMES = "|/-\\"


class _Spinner:
    """ASCII spinner fed by the child's log file. Shows the latest
    'PROGRESS <text>' line the child emitted; apt download lines (Get:N,
    after the 'newly installed' summary) become 'fetching n/total (pkg)'.
    Animation only on a TTY (TB_SPIN=1 forces it, for tests)."""

    def __init__(self, label, logfile):
        self.label = label
        self.logfile = logfile
        self.detail = ""
        self.offset = 0
        self.gets = 0
        self.total = 0
        self.tty = sys.stdout.isatty() or os.environ.get("TB_SPIN") == "1"
        self._stop = threading.Event()
        self._thread = None

    def _poll(self):
        try:
            with open(self.logfile, errors="replace") as f:
                f.seek(self.offset)
                chunk = f.read()
                self.offset = f.tell()
        except OSError:
            return
        for line in chunk.splitlines():
            m = re.match(r"PROGRESS (.*)", line)
            if m:
                self.detail = m.group(1)
                continue
            m = re.search(r"(\d+) newly installed", line)
            if m:
                self.total = int(m.group(1))
            elif self.total and line.startswith("Get:"):
                self.gets += 1
                tok = line.split()
                pkg = tok[-5] if len(tok) >= 8 else ""
                self.detail = f"fetching {self.gets}/{self.total} debs ({pkg})"

    def _animate(self):
        i = 0
        while not self._stop.wait(0.1):
            self._poll()
            if self.tty:
                sys.stdout.write(
                    f"\r\033[K{_SPIN_FRAMES[i % len(_SPIN_FRAMES)]} {self.label}"
                    + (f" ({self.detail})" if self.detail else "")
                )
                sys.stdout.flush()
            i += 1

    def __enter__(self):
        if self.tty:
            self._thread = threading.Thread(target=self._animate, daemon=True)
            self._thread.start()
        else:
            print(f"{self.label}...")
        return self

    def __exit__(self, *exc):
        self._stop.set()
        if self._thread:
            self._thread.join()
        self._poll()
        if self.tty:
            sys.stdout.write("\r\033[K")
            sys.stdout.flush()
        return False


def run_spin(label, argv):
    """Run argv under a spinner with output captured to a temp log. Returns
    (rc, log_lines). On failure the log tail is printed and the log kept."""
    fd, logfile = tempfile.mkstemp(prefix="tb-spin-", suffix=".log", dir="/var/tmp")
    with _Spinner(label, logfile):
        proc = subprocess.Popen(argv, stdout=fd, stderr=subprocess.STDOUT)
        rc = proc.wait()
    os.close(fd)
    with open(logfile, errors="replace") as f:
        lines = f.readlines()
    if rc:
        print(f"{label} failed (full log: {logfile}); last lines:", file=sys.stderr)
        for line in lines[-30:]:
            print(f"    {line}", end="", file=sys.stderr)
    else:
        os.unlink(logfile)
    return rc, lines


# ---------------------------------------------------------------------------
# exec (generic container command; all container ops go through here)
# ---------------------------------------------------------------------------


def cmd_exec(args):
    """tb exec <command...>: run a command inside the build container."""
    if not args.command:
        print("[exec] usage: tb exec [--privileged] <command...>", file=sys.stderr)
        return 2
    cfg = load_active()
    if not cfg:
        return 1
    rc = ensure_sysroot_packages(cfg)
    if rc:
        return rc
    rc = exec_cmd(*args.command, privileged=args.privileged)
    stop_tb_build()
    return rc


# ---------------------------------------------------------------------------
# build / clean (scope: --all default, -s PKG)
# ---------------------------------------------------------------------------


def build_cmd(args, platform):
    cmd = [f"{CC_MOUNT}/topsbot_ws/tools/scripts/build.sh", "-p", platform]
    if getattr(args, "package", None):
        cmd += ["-s", args.package]
    if getattr(args, "verbose", False):
        cmd += ["-r", EVENT_HANDLERS]
    return cmd


def cmd_build(args):
    cfg = load_active()
    if not cfg:
        return 1
    target = active_target()
    platform = cfg.get("platform", "MES20")
    scope = f"pkg:{args.package}" if getattr(args, "package", None) else "all"
    print(f"[build] target={target} variant={cfg.get('variant')} scope={scope}")
    rc = ensure_sysroot_packages(cfg)
    if rc:
        return rc
    rc = ensure_sysroot_deps(cfg)
    if rc:
        return rc
    rc = build_container(*build_cmd(args, platform))
    stop_tb_build()
    return rc


def cmd_clean(args):
    if getattr(args, "container", False):
        name = tb_build_name()
        subprocess.call(
            ["docker", "rm", "-f", name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"[clean] removed {name} (all container state dropped)")
        return 0
    target = active_target()
    if not target:
        return 1
    cfg = load_active()
    if not cfg:
        return 1
    scope = f"pkg:{args.package}" if getattr(args, "package", None) else "all"
    distro = cfg.get("distro") or ""
    print(f"[clean] target={target} variant={cfg.get('variant')} scope={scope}")
    if getattr(args, "package", None):
        pkg = args.package
        ws = "topsbot_ws"
        # debian artifact name: ROS pkg '_' -> '-', tbros-humble- prefix (package.sh)
        deb = "tbros-humble-" + pkg.replace("_", "-")
        rc = container_rm(
            f"{ws}/build/{pkg}",
            f"{ws}/install/share/{pkg}",
            f"{ws}/install/lib/{pkg}",
            f"{ws}/install/share/colcon-core/packages/{pkg}",
            f"{ws}/debsrc/{distro}/{deb}_*",
            f"{ws}/debsrc/{distro}/.work/{pkg}",
        )
    else:
        rc = container_rm(
            "topsbot_ws/build",
            "topsbot_ws/install",
            "topsbot_ws/log",
            "topsbot_ws/debsrc",
        )
    stop_tb_build()
    return rc


# ---------------------------------------------------------------------------
# package (bloom → debian source package)
# ---------------------------------------------------------------------------


def ws_packages():
    """Package names from package.xml under src/ and tools/packages/ (max 4
    directory levels; a package dir is not descended into)."""
    import xml.etree.ElementTree as ET

    out = []
    for base in (SRC, os.path.join(TOOLS_DIR, "packages")):
        for root, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            rel = os.path.relpath(root, base)
            depth = 0 if rel == "." else rel.count(os.sep) + 1
            if "package.xml" in files:
                try:
                    name = (
                        ET.parse(os.path.join(root, "package.xml"))
                        .getroot()
                        .findtext("name")
                    )
                    if name:
                        out.append(name)
                except ET.ParseError:
                    pass
                dirs[:] = []
            elif depth >= 4:
                dirs[:] = []
    return sorted(set(out))


def cmd_package(args):
    if getattr(args, "action", None) == "list":
        print("\n".join(ws_packages()))
        return 0
    cfg = load_active()
    if not cfg:
        return 1
    scope = f"pkg:{args.package}" if getattr(args, "package", None) else "all"
    variant_distro = cfg.get("distro") or ""
    if not variant_distro:
        print(
            "[package] board JSON must set distro (or lunch a variant that has one)",
            file=sys.stderr,
        )
        return 1
    distro = args.distro or variant_distro
    if args.distro and args.distro != variant_distro:
        print(
            f"[package] --distro {args.distro} != lunched variant "
            f"distro {variant_distro}; lunch the matching variant or omit --distro",
            file=sys.stderr,
        )
        return 2
    print(f"[package] scope={scope} distro={distro} variant={cfg.get('variant')}")
    rc = ensure_sysroot_packages(cfg)
    if rc:
        return rc
    cmd = [f"{CC_MOUNT}/topsbot_ws/tools/scripts/package.sh", "--distro", distro]
    if getattr(args, "package", None):
        cmd += ["-s", args.package]
    if getattr(args, "refresh", False):
        cmd.append("--refresh")
    rc = exec_cmd("bash", *cmd)
    stop_tb_build()
    return rc


# ---------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------


def repos_paths(repos_file=None):
    """Parse a repos file (simple YAML subset): repository keys -> src/<key>."""
    paths = []
    with open(repos_file or REPOS_FILE) as f:
        for line in f:
            line = line.rstrip()
            # keys are indented under repositories: (2 spaces, no colon in key)
            if (
                line.startswith("  ")
                and not line.startswith("    ")
                and ":" in line
                and line.endswith(":")
            ):
                key = line.strip().rstrip(":").strip()
                if key and key != "repositories":
                    paths.append(key)
    return paths


def repo_dirty(repo):
    out = subprocess.run(
        ["git", "-C", repo, "status", "--porcelain"], stdout=subprocess.PIPE, text=True
    )
    return out.stdout.strip() != ""


def update_code(cfg):
    """vcs import + pull latest for every clean repo; repos with unsaved
    local changes are skipped with a warning."""
    repos_file = cfg.get("repos", "configs/ros2.repos")
    if not os.path.isabs(repos_file):
        repos_file = os.path.join(WS, repos_file)
    os.makedirs(SRC, exist_ok=True)
    with open(repos_file) as repos:
        run("vcs", "import", SRC, stdin=repos)
    dirty_repos = []
    for key in repos_paths(repos_file):
        repo = os.path.join(SRC, key)
        if not os.path.isdir(os.path.join(repo, ".git")):
            continue
        if repo_dirty(repo):
            dirty_repos.append(repo)
            continue
        run("git", "-C", repo, "pull", "--ff-only")
    if dirty_repos:
        print("[update] repos with unsaved local changes (skipped, not pulled):")
        for r in dirty_repos:
            print(f"    {r}")
    return 0


def _sysroot_ready(path):
    return os.path.isdir(os.path.join(path, "usr", "bin")) and (
        os.path.isdir(os.path.join(path, "opt", "tbros"))
        or os.path.isdir(os.path.join(path, "opt", "ros"))
    )


def confirm_once(prompt):
    """Single yes/no confirmation for destructive refreshes."""
    return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")


def update_sysroot(cfg, download_only=False, extract_only=False, ask=False):
    """Download/extract sysroot from JSON url, or use JSON dir as-is.
    With ask=True, an already-ready sysroot is only rebuilt after the user
    confirms once (local changes inside are dropped)."""
    cfg = resolve_cfg(cfg)
    sysroot_cfg = cfg.get("sysroot") or {}
    url, d = _sysroot_spec(cfg)
    if not url and not (sysroot_cfg.get("dir") or ""):
        print(
            "[update] sysroot.url or sysroot.dir is required for this variant",
            file=sys.stderr,
        )
        return 1
    if not url:
        sr = d if os.path.isabs(d) else os.path.join(CC_ROOT, d)
        if download_only:
            print(
                "[update] sysroot.url is empty; nothing to download",
                file=sys.stderr,
            )
            return 1
        if not _sysroot_ready(sr):
            print(f"[update] sysroot dir is not ready: {sr}", file=sys.stderr)
            return 1
        print("[update] sysroot dir:", sr)
        return 0
    force = False
    if (
        ask
        and not download_only
        and not extract_only
        and _sysroot_ready(sysroot_dir(cfg))
    ):
        if not confirm_once(
            f"[update] sysroot ready: {sysroot_dir(cfg)}\n"
            "[update] re-downloading will delete local changes inside it; continue?"
        ):
            print("[update] canceled; sysroot unchanged")
            return 0
        force = True
    env = dict(os.environ)
    env["TOPSBOT_SYSROOT_URL"] = url
    env["TOPSBOT_SYSROOT_DIR"] = d
    env["TOPSBOT_SYSROOT_FILE"] = sysroot_cfg.get("file") or ""
    env["TOPSBOT_SYSROOT_VARIANT"] = cfg.get("variant") or ""
    sh = os.path.join(SCRIPTS_DIR, "download_sysroot.sh")
    extra = []
    if download_only:
        extra.append("--download-only")
    if extract_only:
        extra.append("--extract-only")
    if force:
        # root-owned sysroot cannot be rm'd from the host; drop it via the
        # container, then let the script rebuild (its own rm becomes a no-op).
        rel = sysroot_rel(cfg)
        if rel:
            container_rm(rel)
        return run("bash", sh, "--force", *extra, env=env)
    return run("bash", sh, *extra, env=env)


def update_docker_image(cfg=None, ask=False):
    """JSON `image` is the local tag (auto if unset). `remote_image` set:
    pull only, then tag. Unset: build from tools/docker/. No silent fallback.
    With ask=True, an already-present image is only refreshed after the user
    confirms once (local changes to the image are dropped)."""
    image = (cfg or {}).get("image") or active_image()
    remote = (cfg or {}).get("remote_image") or ""
    present = (
        subprocess.call(
            ["docker", "image", "inspect", image],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        == 0
    )
    if present:
        if ask:
            how = "pull" if remote else "rebuild"
            if not confirm_once(
                f"[update] image present: {image}\n"
                f"[update] re-running {how} will discard local changes to the image; continue?"
            ):
                print("[update] canceled; image unchanged")
                return 0
        else:
            print("[update] image present:", image)
            return 0
    if remote:
        print(f"[update] pulling {remote}")
        if run("docker", "pull", remote) != 0:
            print(f"[update] pull {remote} failed", file=sys.stderr)
            return 1
        return run("docker", "tag", remote, image)
    dockerfile = os.path.join(DOCKER_DIR, "Dockerfile")
    if not os.path.isfile(dockerfile):
        print(
            f"[update] no local image {image!r} and no remote_image in JSON",
            file=sys.stderr,
        )
        return 1
    suite = (cfg or {}).get("distro") or (cfg or {}).get("variant") or ""
    ver = _UBUNTU.get(suite)
    if not ver:
        print(
            f"[update] unknown suite {suite!r} for tools/docker/ build "
            f"(known: {', '.join(_UBUNTU)})",
            file=sys.stderr,
        )
        return 1
    print(f"[update] building {image} from {DOCKER_DIR} (ubuntu:{ver})")
    return run(
        "docker",
        "build",
        "--build-arg",
        f"UBUNTU_VERSION={ver}",
        "--build-arg",
        f"SUITE={suite}",
        "-t",
        image,
        DOCKER_DIR,
    )


def cmd_update(args):
    which = getattr(args, "update_cmd", "")
    code = which in ("code", "all")
    sysroot = which in ("sysroot", "all")
    docker_image = which in ("docker-image", "all")

    cfg = load_active()
    if not cfg:
        return 1

    rc = 0
    if code:
        rc = update_code(cfg) or rc
    if sysroot:
        rc = update_sysroot(
            cfg,
            download_only=getattr(args, "download_only", False),
            extract_only=getattr(args, "extract_only", False),
            ask=True,
        ) or rc
        if not rc and not getattr(args, "download_only", False):
            rc = ensure_sysroot_packages(cfg) or rc
    if docker_image:
        rc = update_docker_image(cfg, ask=True) or rc
    return rc


# ---------------------------------------------------------------------------
# shell (enter environment)
# ---------------------------------------------------------------------------


def cmd_shell(args):
    if not (args.cross or args.sysroot):
        print("[shell] specify --cross (build env) or --sysroot", file=sys.stderr)
        return 2
    cfg = load_active()
    if not cfg:
        return 1
    rc = ensure_sysroot_packages(cfg)
    if rc:
        return rc
    rc = 0
    if args.cross:
        # Fast cross-build/verify shell: env preloaded by cross_env.sh.
        rc = exec_cmd(
            "bash",
            "-c",
            f"source {CC_MOUNT}/topsbot_ws/tools/scripts/cross_env.sh && "
            'echo "[cross-env] ready — cmake -B build '
            '-DCMAKE_TOOLCHAIN_FILE=$TOPSBOT_TOOLCHAIN_FILE" && exec bash',
            interactive=True,
        )
    if args.sysroot:
        rc = exec_cmd(
            f"{CC_MOUNT}/topsbot_ws/tools/scripts/chroot.sh", privileged=True, interactive=True
        )
    stop_tb_build()
    return rc


# ---------------------------------------------------------------------------
# config (view / write override / merge back to baseline)
# ---------------------------------------------------------------------------


def _set_path(cfg, dotted, value):
    """Set a dotted key (e.g. sysroot.url) in cfg, returning list of key names."""
    parts = dotted.split(".")
    node = cfg
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    node[parts[-1]] = value


def _get_path(cfg, dotted):
    """Read a dotted key (e.g. sysroot.url); None if missing."""
    node = cfg
    for p in dotted.split("."):
        if not isinstance(node, dict) or p not in node:
            return None
        node = node[p]
    return node


def _load_json(path, default=None):
    if os.path.isfile(path):
        with open(path) as f:
            return json.load(f)
    return default if default is not None else {}


def _scoped_key(key, cfg):
    """Map short sysroot./distro keys onto the active variant."""
    if not key or key.startswith("variants."):
        return key
    top = key.split(".", 1)[0]
    variants = cfg.get("variants")
    if (
        top in ("sysroot", "distro", "image", "remote_image", "container")
        and isinstance(variants, dict)
        and variants
    ):
        v = active_variant() or cfg.get("default_variant")
        if v:
            return f"variants.{v}.{key}"
    return key


def cmd_config(args):
    target = active_target()
    if not target:
        return 1

    base_path = os.path.join(board_dir(target), f"{target}.json")
    over_path = os.path.join(board_dir(target), f"{target}.override.json")
    merged = load_target(target)

    def read_key(k):
        if k.startswith("variants."):
            return _get_path(merged, k)
        v = _get_path(resolved, k)
        if v is not None:
            return v
        return _get_path(merged, k)

    if args.merge:
        # write the merged view back into the baseline product config
        over = _load_json(over_path)
        if over:
            with open(base_path, "w") as f:
                json.dump(merged, f, indent=2, ensure_ascii=False)
                f.write("\n")
            os.remove(over_path)
            print(
                f"[config] merged override into {target}.json; removed {target}.override.json"
            )
        else:
            print(f"[config] no override for {target}; nothing to merge")
        return 0

    resolved = load_active()
    if not resolved:
        return 1

    if args.raw:
        if args.keys and "=" not in args.keys[0]:
            print(json.dumps(read_key(args.keys[0]), ensure_ascii=False))
        else:
            print(json.dumps(resolved, ensure_ascii=False))
        return 0

    if args.keys:
        reads = [k for k in args.keys if "=" not in k]
        writes = [k for k in args.keys if "=" in k]
        for k in reads:
            v = read_key(k)
            print(
                json.dumps(v, ensure_ascii=False) if v is not None else f"{k}: (unset)"
            )
        if writes:
            over = _load_json(over_path)
            for kv in writes:
                k, _, v = kv.partition("=")
                if not k or not v:
                    print(
                        f"[config] bad assignment: {kv} (use key=value, dotted keys ok)",
                        file=sys.stderr,
                    )
                    return 1
                scoped = _scoped_key(k, merged)
                _set_path(over, scoped, v)
                if scoped != k:
                    print(f"[config] {k} -> {scoped}")
            with open(over_path, "w") as f:
                json.dump(over, f, indent=2, ensure_ascii=False)
                f.write("\n")
            print(f"[config] wrote {target}.override.json")
        return 0

    print(f"[config] target: {target}  variant: {resolved.get('variant')}")
    print(
        f"  override file: {'yes (' + os.path.basename(over_path) + ')' if os.path.isfile(over_path) else 'no'}"
    )
    for k, v in sorted(resolved.items()):
        print(
            f"  {k}: {json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v}"
        )
    return 0


# ---------------------------------------------------------------------------
# argparse wiring
# ---------------------------------------------------------------------------


class TBHelpParser(argparse.ArgumentParser):
    """`tb -h` shows a compact command list; adding `--full` shows all commands.
    Subcommands declare their visibility at registration time via
    `add_cmd(..., hidden=True)`. `--full` is stripped in main() before
    parsing, so it never reaches a subcommand's own argv."""

    _full = False

    def __init__(self, *args, **kw):
        super().__init__(*args, **kw, add_help=False)
        self.add_argument(
            "-h",
            "--help",
            action="help",
            help="show this help message and exit (--full: list all commands)",
        )

    def format_help(self):
        sub = next(
            (a for a in self._actions if isinstance(a, argparse._SubParsersAction)),
            None,
        )
        removed = {}
        if sub is not None and not self._full:
            hidden = {
                name
                for name, sp in sub.choices.items()
                if getattr(sp, "_tb_hidden", False)
            }
            if hidden:
                for i, ca in enumerate(list(sub._choices_actions)):
                    if ca.dest in hidden:
                        removed[ca] = i
                for ca in removed:
                    sub._choices_actions.remove(ca)
        try:
            body = super().format_help()
        finally:
            if sub is not None:
                for ca, i in sorted(removed.items(), key=lambda kv: kv[1]):
                    sub._choices_actions.insert(i, ca)
        return body


def add_cmd(sub, name, *, hidden=False, **kw):
    """add_parser wrapper: `hidden=True` keeps the command out of the default
    `tb -h` list (still shown with `--full`, still runnable)."""
    sp = sub.add_parser(name, **kw)
    sp._tb_hidden = hidden
    return sp


def build_parser():
    p = TBHelpParser(prog="tb", description="topsbot_cc command CLI")
    sub = p.add_subparsers(dest="cmd", required=True, title="commands", metavar="")

    u = sub.add_parser(
        "update", help="ensure resources ready (fetch missing / refresh)"
    )
    usub = u.add_subparsers(
        dest="update_cmd", required=True, metavar="", title="resources"
    )
    usub.add_parser("code", help="sync source repos (configs/ros2.repos)").set_defaults(
        func=cmd_update
    )
    s = usub.add_parser("sysroot", help="download/extract sysroot")
    s.add_argument(
        "--download-only",
        action="store_true",
        help="download tarball only, do not extract",
    )
    s.add_argument(
        "--extract-only",
        action="store_true",
        help="extract local tarball only, no download",
    )
    s.set_defaults(func=cmd_update)
    usub.add_parser("docker-image", help="ensure the cross image").set_defaults(
        func=cmd_update
    )
    usub.add_parser("all", help="code + sysroot + docker-image").set_defaults(
        func=cmd_update
    )

    for name in ("build", "clean"):
        c = sub.add_parser(name, help=f"{name} workspace (default) or one package")
        c.add_argument(
            "-s", "--package", metavar="PKG", help="single package (default: all)"
        )
        c.add_argument(
            "--all",
            action="store_true",
            dest="all_scope",
            help="whole workspace (default)",
        )
        c.add_argument("--verbose", action="store_true", help="live colcon output")
        if name == "clean":
            c.add_argument(
                "--container",
                action="store_true",
                help="remove the persistent tb-build container (reset)",
            )
        c.set_defaults(func=cmd_build if name == "build" else cmd_clean)

    pk = sub.add_parser(
        "package",
        help="bloom → debian source package (.dsc), workspace (default) or one package",
    )
    pk.add_argument(
        "action",
        nargs="?",
        choices=["list"],
        help="list: print workspace package names and exit",
    )
    pk.add_argument(
        "-s", "--package", metavar="PKG", help="single package (default: all)"
    )
    pk.add_argument(
        "--refresh",
        action="store_true",
        help="refresh rosdep db / bloom env before packaging",
    )
    pk.add_argument(
        "--distro",
        metavar="DISTRO",
        default=None,
        help="ubuntu codename for bloom --os-version "
        "(default: lunched variant distro); "
        "artifacts go to topsbot_ws/debsrc/DISTRO/",
    )
    pk.set_defaults(func=cmd_package)

    sh = add_cmd(
        sub,
        "shell",
        hidden=True,
        help="fast cross-build/verify shell or sysroot shell",
    )
    shg = sh.add_mutually_exclusive_group()
    shg.add_argument(
        "--cross",
        action="store_true",
        help="fast cross-build & verification shell (cross env preloaded)",
    )
    shg.add_argument("--sysroot", action="store_true", help="enter sysroot")
    sh.set_defaults(func=cmd_shell)

    ex = add_cmd(
        sub, "exec", hidden=True, help="run a command inside the build container"
    )
    ex.add_argument("--privileged", action="store_true", help="run with --privileged")
    ex.add_argument("command", nargs=argparse.REMAINDER, help="command to run")
    ex.set_defaults(func=cmd_exec)

    cf = add_cmd(sub, "config", hidden=True, help="view / set target configuration")
    cf.add_argument(
        "keys",
        nargs="*",
        metavar="key[=value]",
        help="read a key, or write it into the override file",
    )
    cf.add_argument(
        "--merge",
        action="store_true",
        help="merge override back into the baseline product config",
    )
    cf.add_argument(
        "--raw",
        action="store_true",
        help="output merged config (or single key) as JSON",
    )
    cf.set_defaults(func=cmd_config)

    return p


def main():
    # Line-buffer stdout so piped logs (tee/CI) interleave tb's own status
    # lines with container output in the order they happen.
    sys.stdout.reconfigure(line_buffering=True)
    # `--full` only affects help output; strip it before parsing so it never
    # leaks into a subcommand's argv (e.g. `tb exec ... -- --full`).
    argv = sys.argv[1:]
    full = "--full" in argv and ("-h" in argv or "--help" in argv)
    if full:
        argv = [a for a in argv if a != "--full"]
    parser = build_parser()
    parser._full = full
    try:
        args = parser.parse_args(argv)
        return args.func(args)
    except KeyboardInterrupt:
        _stop_build_containers()
        print("Interrupted by user", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
