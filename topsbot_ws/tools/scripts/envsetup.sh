# topsbot_cc envsetup — source/lunch (shell) + thin dispatch to tb.py.
#
#   cd /path/to/topsbot_cc
#   source topsbot_ws/tools/scripts/envsetup.sh   (bash/zsh)
#
# Command domains:
#   environment : source envsetup.sh, lunch [target]
#   build       : m, m clean, mm, mm clean              (platform from lunch)
#   misc tools  : tb sync | docker-image | chroot | shell | sysroot | top | help
#
# All command logic lives in tb.py (argparse); this file only keeps the
# parts that must modify the current shell: source exports, lunch (BUILD_TARGET,
# BUILD_VARIANT) and `tb top` (cd). m/mm/tb are thin forwarders.

if [ -n "${BASH_VERSION:-}" ]; then
  _TB_SRC="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _TB_SRC="${(%):-%N}"
else
  _TB_SRC="$0"
fi

_TB_SCRIPTS="$(cd "$(dirname "$_TB_SRC")" && pwd)"
_TB_TOOLS="$(cd "${_TB_SCRIPTS}/.." && pwd)"
export TB_WS="$(cd "${_TB_TOOLS}/.." && pwd)"
export TB_ROOT="$(cd "${TB_WS}/.." && pwd)"
export TB_TARGET_DIR="${TB_WS}/configs/target"
export PYTHONDONTWRITEBYTECODE=1   # no __pycache__ for tb.py runs
TB_PY="${_TB_SCRIPTS}/tb.py"

# ---------------------------------------------------------------------------
# environment domain
# ---------------------------------------------------------------------------

# Expand topsbot_ws/configs/target/<board>/<board>.json into lunch rows:
# id<TAB>board-variant (override merged).
_tb_lunch_py() {
  python3 - "${TB_TARGET_DIR}" "$@" <<'PY'
import glob, json, os, sys

def deep_merge(base, over):
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out

def load_board(path):
    with open(path) as f:
        cfg = json.load(f)
    over = path[: -len(".json")] + ".override.json"
    if os.path.isfile(over):
        with open(over) as f:
            cfg = deep_merge(cfg, json.load(f))
    return cfg

def rows(target_dir):
    out = []
    for path in glob.glob(os.path.join(target_dir, "**", "*.json"), recursive=True):
        if path.endswith(".override.json"):
            continue
        cfg = load_board(path)
        board = cfg.get("name") or os.path.splitext(os.path.basename(path))[0]
        variants = cfg.get("variants")
        if isinstance(variants, dict) and variants:
            default = cfg.get("default_variant") or next(iter(variants))
            for vname, vcfg in variants.items():
                vcfg = vcfg if isinstance(vcfg, dict) else {}
                vid = vcfg.get("id", cfg.get("id", 0))
                try:
                    vid = int(vid)
                except (TypeError, ValueError):
                    vid = 0
                distro = vcfg.get("distro") or vname
                out.append({
                    "id": vid,
                    "name": f"{board}-{vname}",
                    "board": board,
                    "variant": vname,
                    "path": path,
                    "distro": distro,
                    "product": cfg.get("product", ""),
                    "platform": cfg.get("platform", ""),
                    "description": cfg.get("description") or "",
                    "default": vname == default,
                })
        else:
            vid = cfg.get("id", 0)
            try:
                vid = int(vid)
            except (TypeError, ValueError):
                vid = 0
            variant = cfg.get("default_variant") or ""
            name = f"{board}-{variant}" if variant else board
            out.append({
                "id": vid,
                "name": name,
                "board": board,
                "variant": variant,
                "path": path,
                "distro": cfg.get("distro") or variant or "",
                "product": cfg.get("product", ""),
                "platform": cfg.get("platform", ""),
                "description": cfg.get("description") or "",
                "default": True,
            })
    out.sort(key=lambda r: (r["id"], r["name"]))
    return out

def emit(row):
    desc = str(row.get("description") or "").replace("\t", " ")
    print("\t".join([
        row["board"],
        row.get("variant") or "",
        row["path"],
        row.get("distro") or "",
        str(row.get("product") or ""),
        str(row.get("platform") or ""),
        desc,
    ]))

def resolve(target_dir, spec):
    spec = (spec or "").strip()
    if spec.endswith(".json"):
        spec = spec[: -len(".json")]
    found = rows(target_dir)
    if not spec:
        print("[lunch] ERROR: empty selection", file=sys.stderr)
        sys.exit(1)
    hit = None
    if spec.isdigit():
        matches = [r for r in found if str(r["id"]) == spec]
        if len(matches) != 1:
            print(f"[lunch] ERROR: no target with id {spec}", file=sys.stderr)
            sys.exit(1)
        hit = matches[0]
    else:
        matches = [r for r in found if r["name"] == spec]
        if not matches:
            board_rows = [r for r in found if r["board"] == spec]
            if board_rows:
                matches = [r for r in board_rows if r.get("default")] or board_rows[:1]
        if not matches:
            known = ", ".join(r["name"] for r in found) or "(none)"
            print(f"[lunch] ERROR: unknown target or id: {spec}", file=sys.stderr)
            print(f"[lunch] known: {known}", file=sys.stderr)
            sys.exit(1)
        hit = matches[0]
    emit(hit)

cmd = sys.argv[2] if len(sys.argv) > 2 else "list"
target_dir = sys.argv[1]
if cmd == "list":
    for r in rows(target_dir):
        flag = "1" if r.get("default") else "0"
        print(f"{r['id']}\t{r['name']}\t{flag}")
elif cmd == "resolve":
    resolve(target_dir, sys.argv[3] if len(sys.argv) > 3 else "")
else:
    print(f"[lunch] ERROR: unknown helper cmd {cmd}", file=sys.stderr)
    sys.exit(1)
PY
}

_tb_target_list() {
  _tb_lunch_py list
}

_tb_target_default() {
  local first name flag
  while IFS=$'\t' read -r _id name flag; do
    if [[ "${flag}" == "1" ]]; then
      echo "${name}"
      return 0
    fi
    [[ -n "${first:-}" ]] || first="${name}"
  done < <(_tb_target_list)
  echo "${first:-mes20-jammy}"
}

_tb_lunch_current() {
  if [[ -n "${BUILD_TARGET:-}" && -n "${BUILD_VARIANT:-}" ]]; then
    echo "${BUILD_TARGET}-${BUILD_VARIANT}"
  elif [[ -n "${BUILD_TARGET:-}" ]]; then
    echo "${BUILD_TARGET}"
  else
    _tb_target_default
  fi
}

# Select board+variant and export BUILD_TARGET / BUILD_VARIANT in this shell.
_lunch_select() {
  local spec="$1" out board variant file distro product platform desc
  out="$(_tb_lunch_py resolve "${spec}")" || return 1
  IFS=$'\t' read -r board variant file distro product platform desc <<<"${out}"
  export BUILD_TARGET="${board}"
  export BUILD_TARGET_FILE="${file}"
  export BUILD_VARIANT="${variant}"
  echo "[lunch] target=${board} variant=${variant} product=${product} platform=${platform} distro=${distro}"
  if [[ -n "${desc}" ]]; then
    echo "         ${desc}"
  fi
}

# Select a build target: lunch [board|board-variant|id], or interactive menu.
lunch() {
  local arg="${1:-}" sel
  if [[ -n "${arg}" ]]; then
    _lunch_select "${arg}"
    return $?
  fi
  echo ""
  echo "Lunch menu — pick a target by number or name:"
  while IFS=$'\t' read -r id name flag; do
    [[ -n "${name}" ]] || continue
    if [[ "${flag}" == "1" ]]; then
      printf '     %s\t%s (default)\n' "${id}" "${name}"
    else
      printf '     %s\t%s\n' "${id}" "${name}"
    fi
  done < <(_tb_target_list)
  printf 'Selection [default %s]: ' "$(_tb_lunch_current)"
  read -r sel || return 0
  if [[ -z "${sel}" ]]; then
    _lunch_select "$(_tb_lunch_current)"
    return $?
  fi
  _lunch_select "${sel}"
}

# ---------------------------------------------------------------------------
# build domain (thin forwarders to tb.py)
# ---------------------------------------------------------------------------

m() {
  if [[ "${1:-}" == "clean" ]]; then
    shift
    python3 "${TB_PY}" clean "$@"
  else
    python3 "${TB_PY}" build "$@"
  fi
}

# mm: detect the package of the current directory, forward as -s (no auto-detect in tb).
mm() {
  local dir pkg_xml pkg
  dir="$(pwd -P)"
  pkg_xml=""
  while :; do
    if [[ -f "${dir}/package.xml" ]]; then
      pkg_xml="${dir}/package.xml"
      break
    fi
    [[ "${dir}" == "${TB_WS}/src" || "${dir}" == "${TB_WS}/tools/packages" || "${dir}" == "${TB_ROOT}" || "${dir}" == "/" ]] && break
    dir="$(dirname "${dir}")"
  done
  if [[ -z "${pkg_xml}" ]]; then
    echo "[mm] ERROR: no package.xml found (must run inside ${TB_WS}/src or ${TB_WS}/tools/packages)" >&2
    return 1
  fi
  # NB: _TB_SCRIPTS is unset at the end of this file, TB_PY survives; derive
  # the scripts dir from it.
  if ! pkg="$(python3 "${TB_PY%/*}/pkgxml.py" name "${pkg_xml}")"; then
    echo "[mm] ERROR: cannot read package name from ${pkg_xml}" >&2
    return 1
  fi
  echo "[mm] package: ${pkg}"
  if [[ "${1:-}" == "clean" ]]; then
    shift
    python3 "${TB_PY}" clean -s "${pkg}" "$@"
  else
    python3 "${TB_PY}" build -s "${pkg}" "$@"
  fi
}

# ---------------------------------------------------------------------------
# misc tools domain
# ---------------------------------------------------------------------------

tb() {
  local cmd="${1:-}"
  if [[ -z "${cmd}" ]]; then
    python3 "${TB_PY}" --help
    return 0
  fi
  # top must cd in THIS shell; everything else is handled by tb.py.
  if [[ "${cmd}" == "top" ]]; then
    shift
    cd "${TB_ROOT}"
    return 0
  fi
  if [[ "${cmd}" == "help" || "${cmd}" == "-h" || "${cmd}" == "--help" ]]; then
    shift
    python3 "${TB_PY}" --help "$@"
    return 0
  fi
  python3 "${TB_PY}" "$@"
}

_tb_complete() {
  local cur prev cmd words
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]:-}"
  cmd="${COMP_WORDS[1]:-}"
  COMPREPLY=()

  # Extract command names and CLI options directly from tb.py help text so
  # completion stays in sync with argparse definitions.
  _tb_help_words() {
    python3 "${TB_PY}" "$@" 2>/dev/null | awk '
      /^[[:space:]]{4}[a-z0-9][a-z0-9-]*([[:space:]]|$)/ { print $1 }
      /^[[:space:]]+--?[a-zA-Z0-9]/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^--?[a-zA-Z0-9][a-zA-Z0-9-]*,?$/) {
            x = $i
            gsub(",", "", x)
            print x
          }
        }
      }' | awk '!seen[$0]++'
  }

  if [[ "${COMP_CWORD}" -eq 1 ]]; then
    words="$(_tb_help_words --help --full) top help"
    COMPREPLY=( $(compgen -W "${words}" -- "${cur}") )
    unset -f _tb_help_words
    return 0
  fi

  # -s/--package takes a workspace package name (tb package list).
  if [[ "${prev}" == "-s" || "${prev}" == "--package" ]]; then
    COMPREPLY=( $(compgen -W "$(python3 "${TB_PY}" package list 2>/dev/null)" -- "${cur}") )
    unset -f _tb_help_words
    return 0
  fi

  case "${cmd}" in
    update)
      # update has a second-level resource selector (code/sysroot/docker-image/all).
      words="$(_tb_help_words update --help)"
      ;;
    top|help)
      words="-h --help"
      ;;
    *)
      words="$(_tb_help_words "${cmd}" --help)"
      ;;
  esac

  COMPREPLY=( $(compgen -W "${words}" -- "${cur}") )
  unset -f _tb_help_words
}
complete -F _tb_complete tb 2>/dev/null

echo "[env] TB_ROOT=${TB_ROOT}"
echo "[env] run 'lunch' to pick a target; 'm' to build; 'mm' for single package; 'tb help' for tools."
unset _TB_SRC _TB_SCRIPTS _TB_TOOLS