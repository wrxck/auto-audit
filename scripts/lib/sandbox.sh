#!/usr/bin/env bash
# sandbox helper for executing scraped-repo commands without giving them
# the keys to the host. used by the fixer and poc-builder when running
# tests from untrusted repositories. preference order is podman (rootless)
# → docker → bwrap → fail. network is denied by default; add the repo to
# config.json .allow_network_for_repos to upgrade.

# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/common.sh"

# tuneables via env
: "${AUTO_AUDIT_SANDBOX_CPUS:=2}"
: "${AUTO_AUDIT_SANDBOX_MEMORY:=2g}"
: "${AUTO_AUDIT_SANDBOX_PIDS:=256}"
: "${AUTO_AUDIT_SANDBOX_TMPFS_SIZE:=2g}"
: "${AUTO_AUDIT_SANDBOX_IMAGE_NODE:=node:20-slim}"
: "${AUTO_AUDIT_SANDBOX_IMAGE_PYTHON:=python:3.12-slim}"
: "${AUTO_AUDIT_SANDBOX_IMAGE_GENERIC:=debian:stable-slim}"

# detect runtime once per process and cache. preference: podman → docker → bwrap.
_sandbox_runtime() {
  if [ -n "${AUTO_AUDIT_SANDBOX_RUNTIME_CACHE:-}" ]; then
    printf '%s' "$AUTO_AUDIT_SANDBOX_RUNTIME_CACHE"
    return 0
  fi
  local r=""
  if command -v podman >/dev/null 2>&1; then
    r="podman"
  elif command -v docker >/dev/null 2>&1; then
    r="docker"
  elif command -v bwrap >/dev/null 2>&1; then
    r="bwrap"
  fi
  export AUTO_AUDIT_SANDBOX_RUNTIME_CACHE="$r"
  printf '%s' "$r"
}

# pick an image based on repo contents. callers override with
# AUTO_AUDIT_SANDBOX_IMAGE to force a specific image.
_sandbox_pick_image() {
  local repo="$1"
  if [ -n "${AUTO_AUDIT_SANDBOX_IMAGE:-}" ]; then
    printf '%s' "$AUTO_AUDIT_SANDBOX_IMAGE"
    return 0
  fi
  if [ -f "$repo/package.json" ]; then
    printf '%s' "$AUTO_AUDIT_SANDBOX_IMAGE_NODE"
  elif [ -f "$repo/pyproject.toml" ] || [ -f "$repo/requirements.txt" ] || [ -f "$repo/setup.py" ]; then
    printf '%s' "$AUTO_AUDIT_SANDBOX_IMAGE_PYTHON"
  else
    printf '%s' "$AUTO_AUDIT_SANDBOX_IMAGE_GENERIC"
  fi
}

# read sandbox_mode + allow_network_for_repos from the active config, with
# conservative defaults if config is missing.
_sandbox_mode() {
  local cfg
  cfg="$(config_file 2>/dev/null)" || { printf 'strict'; return 0; }
  [ -f "$cfg" ] || { printf 'strict'; return 0; }
  local m
  m="$(jq -r '.sandbox_mode // "strict"' "$cfg" 2>/dev/null || echo strict)"
  case "$m" in
    strict|best-effort|off) printf '%s' "$m" ;;
    *) printf 'strict' ;;
  esac
}

_sandbox_allow_network_for_active_repo() {
  local cfg url owner_name
  cfg="$(config_file 2>/dev/null)" || return 1
  [ -f "$cfg" ] || return 1
  url="$(jq -r '.url // ""' "$cfg" 2>/dev/null || echo "")"
  case "$url" in
    https://github.com/*) owner_name="${url#https://github.com/}" ;;
    git@github.com:*)     owner_name="${url#git@github.com:}" ;;
    *) owner_name="$url" ;;
  esac
  owner_name="${owner_name%.git}"
  owner_name="${owner_name%/}"
  local match
  match="$(jq -r --arg want "$owner_name" --arg prefixed "github.com/$owner_name" \
    '(.allow_network_for_repos // []) | map(tostring) | map(select(. == $want or . == $prefixed)) | length' \
    "$cfg" 2>/dev/null || echo 0)"
  [ "${match:-0}" -gt 0 ]
}

# scream loud banners to stderr so users notice when the sandbox degrades.
_sandbox_banner_bestEffort() {
  printf '\n' >&2
  printf '################################################################\n' >&2
  printf '## AUTO-AUDIT SANDBOX DISABLED (best-effort mode)             ##\n' >&2
  printf '## running untrusted test code directly on the host.          ##\n' >&2
  printf '## install podman/docker/bubblewrap, or set sandbox_mode=strict.##\n' >&2
  printf '################################################################\n' >&2
  printf '\n' >&2
}

_sandbox_banner_off() {
  printf '\n' >&2
  printf '################################################################\n' >&2
  printf '## AUTO-AUDIT SANDBOX IS OFF                                  ##\n' >&2
  printf '## untrusted test code is running on the host with no         ##\n' >&2
  printf '## isolation. do not use this on repos you do not control.    ##\n' >&2
  printf '################################################################\n' >&2
  printf '\n' >&2
}

# run a command against the target repo inside the sandbox.
# usage: run_sandboxed <repo-path> <cmd> [args...]
# returns the command's exit code, or non-zero if the sandbox cannot be set up.
run_sandboxed() {
  local repo="$1"; shift
  [ -d "$repo" ] || die "run_sandboxed: repo path missing: $repo"
  [ "$#" -gt 0 ] || die "run_sandboxed: no command given"

  local mode; mode="$(_sandbox_mode)"
  local runtime; runtime="$(_sandbox_runtime)"

  if [ -z "$runtime" ]; then
    case "$mode" in
      strict)
        err "run_sandboxed: no sandbox runtime found (podman/docker/bwrap)."
        err "install one, or set sandbox_mode=best-effort in config.json to allow unsandboxed execution."
        return 2
        ;;
      best-effort)
        _sandbox_banner_bestEffort
        ( cd "$repo" && "$@" )
        return $?
        ;;
      off)
        _sandbox_banner_off
        ( cd "$repo" && "$@" )
        return $?
        ;;
    esac
  fi

  if [ "$mode" = "off" ]; then
    _sandbox_banner_off
    ( cd "$repo" && "$@" )
    return $?
  fi

  local allow_net=0
  if _sandbox_allow_network_for_active_repo; then
    allow_net=1
    log "run_sandboxed: network allowed for this repo (on the allowlist)"
  fi

  case "$runtime" in
    podman|docker) _sandbox_run_oci "$runtime" "$repo" "$allow_net" "$@" ;;
    bwrap)         _sandbox_run_bwrap "$repo" "$allow_net" "$@" ;;
  esac
}

_sandbox_run_oci() {
  local runtime="$1"; shift
  local repo="$1"; shift
  local allow_net="$1"; shift

  local image; image="$(_sandbox_pick_image "$repo")"
  local net_args=(--network=none)
  [ "$allow_net" = "1" ] && net_args=(--network=bridge)

  log "run_sandboxed: $runtime image=$image network=$([ "$allow_net" = "1" ] && echo bridge || echo none)"
  if ! "$runtime" image inspect "$image" >/dev/null 2>&1; then
    log "run_sandboxed: pulling $image (first-run fetch may take a minute)..."
  fi

  local shell_cmd
  shell_cmd="$(printf '%q ' "$@")"

  "$runtime" run --rm \
    "${net_args[@]}" \
    --read-only \
    --tmpfs "/tmp:rw,size=512m,mode=1777" \
    --tmpfs "/workspace:rw,size=$AUTO_AUDIT_SANDBOX_TMPFS_SIZE,mode=1777" \
    --user "65534:65534" \
    --cpus="$AUTO_AUDIT_SANDBOX_CPUS" \
    --memory="$AUTO_AUDIT_SANDBOX_MEMORY" \
    --pids-limit="$AUTO_AUDIT_SANDBOX_PIDS" \
    --security-opt=no-new-privileges \
    --cap-drop=ALL \
    -e "HOME=/tmp" \
    -v "$repo:/src:ro" \
    -w /workspace \
    "$image" \
    sh -c "cp -a /src/. /workspace/ 2>/dev/null; cd /workspace && $shell_cmd"
}

_sandbox_run_bwrap() {
  local repo="$1"; shift
  local allow_net="$1"; shift

  local net_args=(--unshare-net)
  [ "$allow_net" = "1" ] && net_args=(--share-net)

  log "run_sandboxed: bwrap network=$([ "$allow_net" = "1" ] && echo share || echo none)"

  local tmpdir
  tmpdir="$(mktemp -d -t auto-audit-bwrap.XXXXXX)"
  trap 'rm -rf "$tmpdir"' RETURN

  cp -a "$repo/." "$tmpdir/"

  bwrap \
    --ro-bind /usr /usr \
    --ro-bind /lib /lib \
    --ro-bind-try /lib64 /lib64 \
    --ro-bind-try /bin /bin \
    --ro-bind-try /sbin /sbin \
    --ro-bind-try /etc/alternatives /etc/alternatives \
    --ro-bind-try /etc/ssl /etc/ssl \
    --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
    --proc /proc \
    --dev /dev \
    --tmpfs /tmp \
    --bind "$tmpdir" /workspace \
    --chdir /workspace \
    --unshare-all \
    "${net_args[@]}" \
    --die-with-parent \
    --new-session \
    --clearenv \
    --setenv HOME /tmp \
    --setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$@"
}
