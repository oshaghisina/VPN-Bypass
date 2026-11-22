#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

# State -- servers.txt and the two generated files -- does not necessarily live
# next to the script. The deployed copy under /usr/local/libexec is root-owned,
# so deriving these paths from SCRIPT_DIR hands an interactive user a
# servers.txt they cannot append to (menu "Add server" dies with Permission
# denied) and a stale list the LaunchDaemon never reads (menu "Apply routes"
# then applies the wrong targets and reports success). Resolution order:
# $BYPASS_DATA_DIR, a "data-dir" pointer file beside the script, then the
# script's own directory. Explicit --config/--history/--snapshot still win,
# which is how the LaunchDaemon addresses the shared state.
DATA_DIR="${SCRIPT_DIR}"
if [ -n "${BYPASS_DATA_DIR:-}" ] && [ -d "${BYPASS_DATA_DIR}" ]; then
  DATA_DIR="${BYPASS_DATA_DIR}"
elif [ -r "${SCRIPT_DIR}/data-dir" ]; then
  __data_dir_pointer="$(grep -v '^[[:space:]]*#' "${SCRIPT_DIR}/data-dir" 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' | head -n 1)"
  if [ -n "${__data_dir_pointer}" ] && [ -d "${__data_dir_pointer}" ]; then
    DATA_DIR="${__data_dir_pointer}"
  fi
  unset __data_dir_pointer
fi

CONFIG_FILE="${DATA_DIR}/servers.txt"
HISTORY_FILE="${DATA_DIR}/resolved-history.txt"
SNAPSHOT_FILE="${DATA_DIR}/last-applied.txt"
SSH_CONFIG_FILE="${HOME:-}/.ssh/config"
PLIST_TEMPLATE_FILE="${SCRIPT_DIR}/com.nextcloud.ssh-wireguard-bypass.plist.example"
LAUNCHD_LABEL="com.nextcloud.ssh-wireguard-bypass"
LAUNCHD_PLIST_PATH="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"

LOG_FILE_PATH="/var/log/ssh-wireguard-bypass.log"
NEWSYSLOG_CONF_PATH="/etc/newsyslog.d/${LAUNCHD_LABEL}.conf"

DRY_RUN=0
LOG_TIMESTAMPS=0
TSV_OUTPUT=0
TEST_FAILURES=0

# How long an address stays routed after its hostname stops resolving to it.
# Names behind a CDN rotate through a pool, and dropping a route the moment an
# address leaves the answer moves live connections onto the tunnel mid-stream.
# Past this age the route is deleted and the mapping forgotten, which is what
# keeps both the routing table and the history file bounded.
LINGER_SECONDS="${BYPASS_LINGER_SECONDS:-86400}"
[[ "${LINGER_SECONDS}" =~ ^[0-9]{1,9}$ ]] || LINGER_SECONDS=86400
LINGER_SECONDS=$((10#${LINGER_SECONDS}))
RUN_EPOCH="$(date +%s)"

SERVERS=()
TARGET_IPS=()
CURRENT_IPS=()
HISTORY_IPS=()
REMOVAL_IPS=()
KEEP_IPS=()
REJECTED_IPS=()
HISTORY_KEYS=()
HISTORY_SEEN=()
HISTORY_FILE_IPS=()
SNAPSHOT_IPS=()
STALE_CANDIDATE_IPS=()
KERNEL_HOST_ROUTES=()
LOCAL_ADDRS=()
EXPLAINED_IPS=()
IMPORT_KEYS=()
INVOCATION_ARGS=()
RESOLVE_CACHE_HOSTS=()
RESOLVE_CACHE_ANSWERS=()
RESOLVED_ANSWERS=""

usage() {
  cat <<'EOF'
Usage:
  manage-ssh-bypass-routes.sh [--config /path/to/servers.txt] [--history /path/to/resolved-history.txt] [--snapshot /path/to/last-applied.txt] [--ssh-config /path/to/config] [--dry-run] [--timestamps] [--tsv] <action> [value]
  manage-ssh-bypass-routes.sh [--config /path/to/servers.txt] [--history /path/to/resolved-history.txt] [--snapshot /path/to/last-applied.txt] [--ssh-config /path/to/config]

Actions:
  menu             Show the interactive menu.
  view             Show configured servers, current IPv4s, remembered history, and warnings.
  add VALUE        Add a server hostname, IPv4 address, or http(s) URL to the config file.
  delete VALUE     Delete an exact server hostname or IPv4 address from the config file.
  apply            Add or refresh host routes for the current targets and delete
                   routes for targets that are no longer wanted.
  remove           Remove host routes for config, history, and snapshot targets.
  status           Show routing state for configured servers and snapshot-only targets.
  test             Verify whether each current, remembered, or snapshot-only target is
                   bypassed. Exits 1 if any target fails.
  prune-history    Trim remembered history to what currently resolves.
  import-ssh-config
                   Discover importable targets from ~/.ssh/config and add them to the config file.
  install-launchd  Install or update the system LaunchDaemon.
  uninstall-launchd
                   Remove the installed system LaunchDaemon.
  launchd-status   Show install and load status for the system LaunchDaemon.
  print-gateway    Print the detected physical gateway, interface, and any active tunnel interfaces.

Flags:
  --dry-run        Preview mutating actions without changing files, routes, or launchd state.
  --timestamps     Prefix every output line with a timestamp (used by the LaunchDaemon).
  --tsv            With status or test only: print tab-separated records instead of
                   the human report (see README "Machine-readable output").

Environment:
  BYPASS_DATA_DIR        Directory holding servers.txt and the generated state files.
  BYPASS_LINGER_SECONDS  How long an address stays routed after its hostname stops
                         resolving to it (default 86400).

Config format:
  One hostname or IPv4 address per line.
  Blank lines and lines beginning with # are ignored.

History format:
  One hostname-to-IPv4 mapping per line as: hostname ip last-seen-epoch
  Blank lines and lines beginning with # are ignored.
  Only public addresses are remembered for a hostname; a private, loopback or
  otherwise non-public DNS answer is treated as hijacked and ignored.

Snapshot format:
  One IPv4 address per line, with optional comment headers.

Examples:
  ./manage-ssh-bypass-routes.sh
  ./manage-ssh-bypass-routes.sh view
  ./manage-ssh-bypass-routes.sh add ssh.example.com
  ./manage-ssh-bypass-routes.sh add https://panel.example.com/
  ./manage-ssh-bypass-routes.sh import-ssh-config
  ./manage-ssh-bypass-routes.sh --dry-run install-launchd
  sudo ./manage-ssh-bypass-routes.sh apply
EOF
}

log_prefix() {
  [ "${LOG_TIMESTAMPS}" -eq 1 ] || return 0
  printf '%s ' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
}

log() {
  log_prefix
  printf '%s\n' "$*"
}

# One machine-readable record for `status --tsv` / `test --tsv`, written to
# fd 3 (report_routes points fd 3 at the real stdout and silences the human
# text). Fields are tab-separated; an empty field is written as "-" so that
# consumers splitting on runs of whitespace still see every column, and any
# tab or newline inside a value is flattened to a space. The record layout is
# documented in README.md under "Machine-readable output".
tsv_record() {
  local field out=""
  local first=1

  [ "${TSV_OUTPUT}" -eq 1 ] || return 0
  for field in "$@"; do
    field="${field//$'\t'/ }"
    field="${field//$'\n'/ }"
    [ -n "${field}" ] || field="-"
    if [ "${first}" -eq 1 ]; then
      out="${field}"
      first=0
    else
      out="${out}"$'\t'"${field}"
    fi
  done
  printf '%s\n' "${out}" >&3
}

warn() {
  {
    log_prefix
    printf 'WARN: %s\n' "$*"
  } >&2
}

die() {
  {
    log_prefix
    printf 'ERROR: %s\n' "$*"
  } >&2
  exit 1
}

dry_run_log() {
  log_prefix
  printf 'DRY-RUN: %s\n' "$*"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

is_ipv4() {
  local value="$1"
  local octet
  local old_ifs="${IFS}"

  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS='.'
  for octet in ${value}; do
    if [ "${octet}" -lt 0 ] || [ "${octet}" -gt 255 ]; then
      IFS="${old_ifs}"
      return 1
    fi
  done
  IFS="${old_ifs}"
  return 0
}

is_valid_hostname() {
  local value="$1"

  [ -n "${value}" ] || return 1
  [[ "${value}" =~ [[:space:]] ]] && return 1
  [[ "${value}" =~ [/@:] ]] && return 1
  [[ "${value}" =~ ^- ]] && return 1
  [[ "${value}" =~ -$ ]] && return 1
  # A name whose last label is all digits is not a hostname. The resolver reads
  # it as a shorthand IPv4 address -- "2" becomes 0.0.0.2 -- which is how a
  # menu choice typed at the "Add server" prompt once ended up routed.
  [[ "${value}" =~ (^|\.)[0-9]+$ ]] && return 1
  [[ "${value}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?))*$ ]]
}

extract_host_from_supported_url() {
  local value="$1"
  local scheme rest authority host port

  [[ "${value}" == *"://"* ]] || return 1

  scheme="${value%%://*}"
  rest="${value#*://}"
  scheme="$(printf '%s' "${scheme}" | tr '[:upper:]' '[:lower:]')"

  case "${scheme}" in
    http|https) ;;
    *) return 1 ;;
  esac

  [ -n "${rest}" ] || return 1

  authority="${rest%%[/?#]*}"
  [ -n "${authority}" ] || return 1

  [[ "${authority}" == *"@"* ]] && return 1
  [[ "${authority}" == *"["* ]] && return 1
  [[ "${authority}" == *"]"* ]] && return 1

  case "${authority}" in
    *:*)
      case "${authority}" in
        *:*:*) return 1 ;;
      esac
      host="${authority%%:*}"
      port="${authority#*:}"
      [ -n "${host}" ] || return 1
      [ -n "${port}" ] || return 1
      [[ "${port}" =~ ^[0-9]+$ ]] || return 1
      ;;
    *)
      host="${authority}"
      ;;
  esac

  [ -n "${host}" ] || return 1
  printf '%s\n' "${host}"
}

normalize_entry() {
  local value

  value="$(trim "$1")"
  [ -n "${value}" ] || return 1

  if [[ "${value}" == *"://"* ]]; then
    value="$(extract_host_from_supported_url "${value}" 2>/dev/null || true)"
    [ -n "${value}" ] || return 1
  fi

  if is_ipv4 "${value}"; then
    printf '%s\n' "${value}"
    return 0
  fi

  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  value="${value%.}"

  is_valid_hostname "${value}" || return 1
  printf '%s\n' "${value}"
}

entry_type() {
  if is_ipv4 "$1"; then
    printf 'ipv4\n'
  else
    printf 'hostname\n'
  fi
}

array_contains() {
  local needle="$1"
  shift

  local item
  for item in "$@"; do
    [ "${item}" = "${needle}" ] && return 0
  done

  return 1
}

append_unique() {
  local array_name="$1"
  local value="$2"

  case "${array_name}" in
    SERVERS)
      [ "${#SERVERS[@]}" -gt 0 ] && array_contains "${value}" "${SERVERS[@]}" && return 0
      SERVERS+=("${value}")
      ;;
    TARGET_IPS)
      [ "${#TARGET_IPS[@]}" -gt 0 ] && array_contains "${value}" "${TARGET_IPS[@]}" && return 0
      TARGET_IPS+=("${value}")
      ;;
    CURRENT_IPS)
      [ "${#CURRENT_IPS[@]}" -gt 0 ] && array_contains "${value}" "${CURRENT_IPS[@]}" && return 0
      CURRENT_IPS+=("${value}")
      ;;
    HISTORY_IPS)
      [ "${#HISTORY_IPS[@]}" -gt 0 ] && array_contains "${value}" "${HISTORY_IPS[@]}" && return 0
      HISTORY_IPS+=("${value}")
      ;;
    REMOVAL_IPS)
      [ "${#REMOVAL_IPS[@]}" -gt 0 ] && array_contains "${value}" "${REMOVAL_IPS[@]}" && return 0
      REMOVAL_IPS+=("${value}")
      ;;
    KEEP_IPS)
      [ "${#KEEP_IPS[@]}" -gt 0 ] && array_contains "${value}" "${KEEP_IPS[@]}" && return 0
      KEEP_IPS+=("${value}")
      ;;
    REJECTED_IPS)
      [ "${#REJECTED_IPS[@]}" -gt 0 ] && array_contains "${value}" "${REJECTED_IPS[@]}" && return 0
      REJECTED_IPS+=("${value}")
      ;;
    HISTORY_FILE_IPS)
      [ "${#HISTORY_FILE_IPS[@]}" -gt 0 ] && array_contains "${value}" "${HISTORY_FILE_IPS[@]}" && return 0
      HISTORY_FILE_IPS+=("${value}")
      ;;
    STALE_CANDIDATE_IPS)
      [ "${#STALE_CANDIDATE_IPS[@]}" -gt 0 ] && array_contains "${value}" "${STALE_CANDIDATE_IPS[@]}" && return 0
      STALE_CANDIDATE_IPS+=("${value}")
      ;;
    SNAPSHOT_IPS)
      [ "${#SNAPSHOT_IPS[@]}" -gt 0 ] && array_contains "${value}" "${SNAPSHOT_IPS[@]}" && return 0
      SNAPSHOT_IPS+=("${value}")
      ;;
    EXPLAINED_IPS)
      [ "${#EXPLAINED_IPS[@]}" -gt 0 ] && array_contains "${value}" "${EXPLAINED_IPS[@]}" && return 0
      EXPLAINED_IPS+=("${value}")
      ;;
    IMPORT_KEYS)
      [ "${#IMPORT_KEYS[@]}" -gt 0 ] && array_contains "${value}" "${IMPORT_KEYS[@]}" && return 0
      IMPORT_KEYS+=("${value}")
      ;;
    *)
      die "Unsupported internal array: ${array_name}"
      ;;
  esac
}

# Tunnel devices that a full-tunnel VPN can live on. WireGuard and OpenVPN
# Connect use utun; community OpenVPN builds and Tunnelblick can use tun/tap via
# tuntaposx; macOS IKEv2 uses ipsec and L2TP/PPTP use ppp. None of them can ever
# carry the bypass, so none of them may be picked as the "physical" path.
is_tunnel_interface() {
  case "$1" in
    utun*|tun*|tap*|ppp*|ipsec*|gpd*|pdp_ip*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_physical_interface() {
  if is_tunnel_interface "$1"; then
    return 1
  fi

  case "$1" in
    lo*|gif*|stf*|bridge*|awdl*|llw*|anpi*|ap*|vmenet*|vmnet*|feth*|XHC*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

# Tunnel interfaces currently holding a default-ish route. WireGuard and OpenVPN
# with "redirect-gateway def1" install 0/1 plus 128.0/1 and leave the real
# default alone; plain "redirect-gateway" replaces the default outright.
# Diagnostic only -- nothing here decides routing.
detect_tunnel_interfaces() {
  netstat -rn -f inet 2>/dev/null | awk '
    ($1 == "default" || $1 == "0/1" || $1 == "128.0/1") && $4 != "" { print $4 }
  ' | while IFS= read -r iface; do
    is_tunnel_interface "${iface}" && printf '%s\n' "${iface}"
  done | sort -u
}

interface_inet_address() {
  ifconfig "$1" 2>/dev/null | awk '/^[[:space:]]*inet /{print $2; exit}'
}

interface_is_active() {
  local iface="$1"

  ifconfig "${iface}" 2>/dev/null | head -1 | grep -q 'RUNNING' || return 1
  [ -n "$(interface_inet_address "${iface}")" ]
}

ipv4_to_int() {
  local o1 o2 o3 o4
  local old_ifs="${IFS}"

  IFS='.' read -r o1 o2 o3 o4 <<< "$1"
  IFS="${old_ifs}"
  printf '%s' "$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))"
}

# A physical gateway must sit on the interface's own subnet. This is what stops
# a stale or tunnel-side address from being adopted and blackholing every
# target, which is exactly how the August 2026 outage presented.
gateway_is_on_link() {
  local iface="$1"
  local gateway="$2"
  local addr mask_hex mask addr_int gw_int

  read -r addr mask_hex <<< "$(
    ifconfig "${iface}" 2>/dev/null | awk '/^[[:space:]]*inet /{print $2, $4; exit}'
  )"

  [ -n "${addr:-}" ] && [ -n "${mask_hex:-}" ] || return 1
  is_ipv4 "${addr}" || return 1
  [[ "${mask_hex}" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || return 1

  mask=$(( mask_hex ))
  addr_int="$(ipv4_to_int "${addr}")"
  gw_int="$(ipv4_to_int "${gateway}")"

  [ "$(( addr_int & mask ))" -eq "$(( gw_int & mask ))" ]
}

# Usable physical interfaces as service|device, in the order macOS itself
# prefers them. VPN services are listed here too but carry an empty Device, and
# disabled services are marked (*); both are dropped.
physical_interface_candidates() {
  local service device

  networksetup -listnetworkserviceorder 2>/dev/null | awk '
    /^\(/ {
      if ($0 ~ /^\(Hardware Port:/) {
        dev = $0
        sub(/^.*Device: /, "", dev)
        sub(/\).*$/, "", dev)
        if (name != "" && dev != "") print name "|" dev
        name = ""
        next
      }
      name = $0
      sub(/^\([0-9*]+\) /, "", name)
      if ($0 ~ /^\(\*\)/) name = ""
      next
    }
  ' | while IFS='|' read -r service device; do
    is_physical_interface "${device}" || continue
    interface_is_active "${device}" || continue
    printf '%s|%s\n' "${service}" "${device}"
  done

  # Anything active that networksetup did not list, in case it is unavailable
  # or the hardware has no configured service.
  ifconfig -l 2>/dev/null | tr ' ' '\n' | while IFS= read -r device; do
    [ -n "${device}" ] || continue
    is_physical_interface "${device}" || continue
    interface_is_active "${device}" || continue
    printf '%s|%s\n' "${device}" "${device}"
  done
}

# Four sources, cheapest and most trustworthy first. The later ones exist
# because a VPN that replaces the default route -- OpenVPN's "redirect-gateway"
# without def1, and anything else that hijacks rather than splits -- erases the
# only evidence source 1 reads.
gateway_for_interface() {
  local iface="$1"
  local service="${2:-}"
  local gateway found_interface

  # 1. An unscoped default route already pointing at this interface. True with
  #    no VPN, with WireGuard, and with OpenVPN's def1 split default.
  gateway="$(
    netstat -rn -f inet 2>/dev/null | awk -v want="${iface}" '
      $1 == "default" && $4 == want && $2 ~ /^([0-9]+\.){3}[0-9]+$/ { print $2; exit }
    '
  )"
  if [ -n "${gateway}" ]; then
    printf '%s\n' "${gateway}"
    return 0
  fi

  # 2. The interface-scoped default. macOS keeps one per network service, and a
  #    VPN that takes over the global default usually leaves it in place. The
  #    interface must be checked too: a scoped lookup with no scoped route falls
  #    through to the global table and would hand back the tunnel's gateway.
  read -r gateway found_interface <<< "$(
    route -n get -ifscope "${iface}" default 2>/dev/null | awk -F': ' '
      /^[[:space:]]*gateway:/ { gw = $2 }
      /^[[:space:]]*interface:/ { ifn = $2 }
      END { print gw, ifn }
    '
  )"
  if [ -n "${gateway:-}" ] && [ "${found_interface:-}" = "${iface}" ] && is_ipv4 "${gateway}"; then
    printf '%s\n' "${gateway}"
    return 0
  fi

  # 3. The DHCP router option, which no routing-table change can disturb.
  gateway="$(trim "$(ipconfig getoption "${iface}" router 2>/dev/null)")"
  if [ -n "${gateway}" ] && is_ipv4 "${gateway}"; then
    printf '%s\n' "${gateway}"
    return 0
  fi

  # 4. A statically configured router on the network service.
  if [ -n "${service}" ]; then
    gateway="$(
      networksetup -getinfo "${service}" 2>/dev/null | awk -F': ' '
        /^Router: / { print $2; exit }
      '
    )"
    gateway="$(trim "${gateway}")"
    if [ -n "${gateway}" ] && is_ipv4 "${gateway}"; then
      printf '%s\n' "${gateway}"
      return 0
    fi
  fi

  return 1
}

detect_physical_gateway() {
  local service interface gateway local_ip
  local fallback=""
  local -a seen=()

  while IFS='|' read -r service interface; do
    [ -n "${interface:-}" ] || continue
    if [ "${#seen[@]}" -gt 0 ] && array_contains "${interface}" "${seen[@]}"; then
      continue
    fi
    seen+=("${interface}")

    gateway="$(gateway_for_interface "${interface}" "${service}")" || continue
    [ -n "${gateway}" ] || continue

    local_ip="$(interface_inet_address "${interface}")"
    [ -n "${local_ip}" ] || continue

    if gateway_is_on_link "${interface}" "${gateway}"; then
      printf '%s|%s|%s|%s\n' "${gateway}" "${interface}" "${service}" "${local_ip}"
      return 0
    fi

    [ -n "${fallback}" ] || fallback="${gateway}|${interface}|${service}|${local_ip}"
  done < <(physical_interface_candidates)

  if [ -n "${fallback}" ]; then
    warn "No on-link physical gateway found; falling back to ${fallback%%|*} which is off-subnet."
    printf '%s\n' "${fallback}"
    return 0
  fi

  return 1
}

require_root_if_needed() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    return 0
  fi

  [ "${EUID}" -eq 0 ] || die "Run this action with sudo."
}

action_requires_root() {
  case "$1" in
    apply|remove|install-launchd|uninstall-launchd)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_invocation_args() {
  local action="$1"
  local value="${2-}"

  INVOCATION_ARGS=(
    --config "${CONFIG_FILE}"
    --history "${HISTORY_FILE}"
    --snapshot "${SNAPSHOT_FILE}"
    --ssh-config "${SSH_CONFIG_FILE}"
  )

  if [ "${DRY_RUN}" -eq 1 ]; then
    INVOCATION_ARGS+=(--dry-run)
  fi

  if [ "${LOG_TIMESTAMPS}" -eq 1 ]; then
    INVOCATION_ARGS+=(--timestamps)
  fi

  if [ "${TSV_OUTPUT}" -eq 1 ]; then
    INVOCATION_ARGS+=(--tsv)
  fi

  INVOCATION_ARGS+=("${action}")

  if [ -n "${value}" ]; then
    INVOCATION_ARGS+=("${value}")
  fi
}

run_with_sudo() {
  local action="$1"
  local value="${2-}"

  build_invocation_args "${action}" "${value}"
  log "Requesting sudo for ${action}..."
  sudo "${SCRIPT_PATH}" "${INVOCATION_ARGS[@]}"
}

run_menu_action() {
  local action="$1"
  local function_name="$2"

  if action_requires_root "${action}" && [ "${DRY_RUN}" -ne 1 ] && [ "${EUID}" -ne 0 ]; then
    run_with_sudo "${action}"
    return $?
  fi

  "${function_name}"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\/&|]/\\&/g'
}

# apply normally runs as root while the state files sit in a directory the
# invoking user owns. Root must therefore never follow a link planted there: a
# redirect, chmod or chown through one lets any process running as that user
# create or take over a file elsewhere on the system. So root refuses a linked
# state file outright, never creates one in place, and sets owner and mode on a
# private temp file before renaming it over the destination.
refuse_symlink_as_root() {
  [ "${EUID}" -eq 0 ] || return 0
  [ -L "$1" ] || return 0
  die "Refusing to use $1 as root: it is a symbolic link."
}

# Root only names the line. Echoing a rejected line into the daemon log would
# copy out whatever a swapped-in file happens to contain.
bad_line_label() {
  if [ "${EUID}" -eq 0 ]; then
    printf 'line %s' "$1"
  else
    printf 'line %s (%s)' "$1" "$2"
  fi
}

# install_state_file TMP DEST [MODE] [OWNER]
install_state_file() {
  local tmp_file="$1"
  local destination="$2"
  local mode="${3:-644}"
  local owner="${4:-}"

  refuse_symlink_as_root "${destination}"
  if [ -d "${destination}" ]; then
    rm -f "${tmp_file}"
    return 1
  fi

  chmod "${mode}" "${tmp_file}" >/dev/null 2>&1 || true

  if [ "${EUID}" -eq 0 ]; then
    if [ -z "${owner}" ]; then
      if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        owner="${SUDO_UID}:${SUDO_GID}"
      else
        # The daemon has no SUDO_UID. Match the directory so the files it
        # writes stay manageable by whoever owns the rest of the state.
        owner="$(stat -f '%u:%g' "$(dirname "${destination}")" 2>/dev/null || true)"
      fi
    fi
    if [ -n "${owner}" ]; then
      chown "${owner}" "${tmp_file}" >/dev/null 2>&1 || true
    fi
  fi

  mv -f -h "${tmp_file}" "${destination}"
}

read_server_list() {
  [ -f "${CONFIG_FILE}" ] || die "Config file not found: ${CONFIG_FILE}"
  refuse_symlink_as_root "${CONFIG_FILE}"

  SERVERS=()

  local raw trimmed normalized
  local line_no=0
  while IFS= read -r raw || [ -n "${raw}" ]; do
    line_no=$((line_no + 1))
    trimmed="$(trim "${raw}")"

    [ -n "${trimmed}" ] || continue
    [[ "${trimmed}" =~ ^# ]] && continue

    normalized="$(normalize_entry "${trimmed}" 2>/dev/null || true)"
    if [ -z "${normalized}" ]; then
      warn "Skipping invalid server in ${CONFIG_FILE}: $(bad_line_label "${line_no}" "${trimmed}")"
      continue
    fi

    if [ "${#SERVERS[@]}" -gt 0 ] && array_contains "${normalized}" "${SERVERS[@]}"; then
      warn "Skipping duplicate server in ${CONFIG_FILE}: ${normalized}"
      continue
    fi

    SERVERS+=("${normalized}")
  done < "${CONFIG_FILE}"
}

# Loads the remembered hostname-to-IPv4 mappings.
#
#   HISTORY_KEYS      host|ip, one per usable mapping
#   HISTORY_SEEN      matching epoch of the last run that resolved it; 0 for a
#                     line written before timestamps existed
#   HISTORY_FILE_IPS  every address the file names, usable or not, so apply and
#                     remove can still clean up a route for an address this
#                     version refuses to remember
read_history_keys() {
  HISTORY_KEYS=()
  HISTORY_SEEN=()
  HISTORY_FILE_IPS=()

  [ -e "${HISTORY_FILE}" ] || [ -L "${HISTORY_FILE}" ] || return 0
  refuse_symlink_as_root "${HISTORY_FILE}"

  if [ ! -f "${HISTORY_FILE}" ] || [ ! -r "${HISTORY_FILE}" ]; then
    warn "History file is not readable: ${HISTORY_FILE}"
    warn "Run a privileged action like apply once, or fix ownership manually, to restore normal access."
    return 0
  fi

  local raw host ip seen
  local line_no=0
  while IFS= read -r raw || [ -n "${raw}" ]; do
    line_no=$((line_no + 1))
    read -r host ip seen _ <<< "${raw}"
    [ -n "${host}" ] || continue
    [[ "${host}" == \#* ]] && continue

    # Lines this script wrote are already normalized; only pay for the full
    # normalization when a hand edit needs it.
    if ! is_valid_hostname "${host}"; then
      host="$(normalize_entry "${host}" 2>/dev/null || true)"
    fi

    if [ -z "${host}" ] || is_ipv4 "${host}" || ! is_ipv4 "${ip}"; then
      warn "Skipping invalid history entry in ${HISTORY_FILE}: $(bad_line_label "${line_no}" "${raw}")"
      continue
    fi

    append_unique HISTORY_FILE_IPS "${ip}"

    # A non-public answer for a hostname is a hijacked or filtered reply (see
    # collect_entry_targets). Older versions recorded those; drop them here.
    is_public_ipv4 "${ip}" || continue

    if [[ "${seen}" =~ ^[0-9]{1,12}$ ]]; then
      seen=$((10#${seen}))
    else
      seen=0
    fi

    history_set "${host}" "${ip}" "${seen}"
  done < "${HISTORY_FILE}"
}

write_history_file_from_keys() {
  local tmp_file key
  local i=0

  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_run_log "Would write ${HISTORY_FILE} with ${#HISTORY_KEYS[@]} hostname-to-IPv4 mappings"
    return 0
  fi

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ssh-bypass-history.XXXXXX")" || return 1
  {
    printf '# One hostname-to-IPv4 mapping per line.\n'
    printf '# Format: hostname ip last-seen-epoch\n'
    while [ "${i}" -lt "${#HISTORY_KEYS[@]}" ]; do
      key="${HISTORY_KEYS[$i]}"
      printf '%s %s %s\n' "${key%%|*}" "${key##*|}" "${HISTORY_SEEN[$i]}"
      i=$((i + 1))
    done
  } > "${tmp_file}"

  install_state_file "${tmp_file}" "${HISTORY_FILE}"
}

read_snapshot_file() {
  SNAPSHOT_IPS=()

  [ -e "${SNAPSHOT_FILE}" ] || [ -L "${SNAPSHOT_FILE}" ] || return 0
  refuse_symlink_as_root "${SNAPSHOT_FILE}"

  if [ ! -f "${SNAPSHOT_FILE}" ] || [ ! -r "${SNAPSHOT_FILE}" ]; then
    warn "Snapshot file is not readable: ${SNAPSHOT_FILE}"
    warn "Run a privileged action like apply once, or fix ownership manually, to restore normal access."
    return 0
  fi

  local raw trimmed
  local line_no=0
  while IFS= read -r raw || [ -n "${raw}" ]; do
    line_no=$((line_no + 1))
    trimmed="$(trim "${raw}")"
    [ -n "${trimmed}" ] || continue
    [[ "${trimmed}" =~ ^# ]] && continue

    if ! is_ipv4 "${trimmed}"; then
      warn "Skipping invalid snapshot entry in ${SNAPSHOT_FILE}: $(bad_line_label "${line_no}" "${trimmed}")"
      continue
    fi

    append_unique SNAPSHOT_IPS "${trimmed}"
  done < "${SNAPSHOT_FILE}"
}

# A gatewayed host route is bound by the kernel to the source address the
# interface held when the route was created (rt_ifa). If the interface later
# picks up a different address on the same subnet -- same gateway, same
# interface -- route(8) still reports the route as correct, but an unbound
# connect() selects the address that no longer exists and fails immediately
# with EADDRNOTAVAIL ("Can't assign requested address"). Gateway and interface
# alone therefore cannot tell a live route from a stale one. Two checks cover
# it: the source address in use at apply time is recorded in the snapshot and
# compared on every later apply, and each route's own bound address is read
# back from "route -n -v get" (see route_source_address), which is the only
# place route(8) shows it.
SNAPSHOT_SOURCE_IP=""
APPLIED_SOURCE_IP=""

read_snapshot_source_ip() {
  SNAPSHOT_SOURCE_IP=""
  [ -f "${SNAPSHOT_FILE}" ] && [ -r "${SNAPSHOT_FILE}" ] || return 0
  refuse_symlink_as_root "${SNAPSHOT_FILE}"

  local value
  value="$(sed -n 's/^# source-ip:[[:space:]]*//p' "${SNAPSHOT_FILE}" | head -n 1)"
  value="$(trim "${value}")"
  if [ -n "${value}" ] && is_ipv4 "${value}"; then
    SNAPSHOT_SOURCE_IP="${value}"
  fi
}

write_snapshot_file() {
  local tmp_file ip timestamp

  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_run_log "Would write ${SNAPSHOT_FILE} with ${#TARGET_IPS[@]} applied IPv4 targets"
    return 0
  fi

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ssh-bypass-snapshot.XXXXXX")" || return 1
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
  {
    printf '# Last successful apply at %s\n' "${timestamp}"
    if [ -n "${APPLIED_SOURCE_IP}" ]; then
      printf '# source-ip: %s\n' "${APPLIED_SOURCE_IP}"
    fi
    if [ "${#TARGET_IPS[@]}" -gt 0 ]; then
      for ip in "${TARGET_IPS[@]}"; do
        printf '%s\n' "${ip}"
      done
    fi
  } > "${tmp_file}"

  install_state_file "${tmp_file}" "${SNAPSHOT_FILE}"
}

# history_set HOST IP SEEN -- records a mapping, keeping the newest timestamp.
history_set() {
  local key="$1|$2"
  local seen="$3"
  local i=0

  while [ "${i}" -lt "${#HISTORY_KEYS[@]}" ]; do
    if [ "${HISTORY_KEYS[$i]}" = "${key}" ]; then
      if [ "${seen}" -gt "${HISTORY_SEEN[$i]}" ]; then
        HISTORY_SEEN[i]="${seen}"
      fi
      return 0
    fi
    i=$((i + 1))
  done

  HISTORY_KEYS+=("${key}")
  HISTORY_SEEN+=("${seen}")
}

# Adds HOST's remembered addresses to HISTORY_IPS and REMOVAL_IPS, and to
# KEEP_IPS those that should still be routed:
#
#   - any seen within LINGER_SECONDS, which includes the ones just resolved;
#   - when the name has no usable answer right now (RESOLVED=0), its most
#     recent answer set, however old. Losing DNS must not tear down the bypass:
#     these names are often unresolvable through the tunnel's own resolver, or
#     answered with a filtering sinkhole, exactly while the bypass is needed.
#
# This fills the arrays directly rather than printing for the caller to read
# back through "done < <(...)". Under the bash 3.2 that macOS ships, each such
# process substitution in the per-server loop left a descriptor open for the
# rest of the run. One per server per pass put a run with 75 hostnames at about
# 150 open descriptors against launchd's default limit of 256, and past that
# limit every later command substitution silently returns nothing.
history_collect_for_host() {
  local host="$1"
  local resolved="$2"
  local i key seen ip
  local newest=-1

  i=0
  while [ "${i}" -lt "${#HISTORY_KEYS[@]}" ]; do
    key="${HISTORY_KEYS[$i]}"
    if [ "${key%%|*}" = "${host}" ] && [ "${HISTORY_SEEN[$i]}" -gt "${newest}" ]; then
      newest="${HISTORY_SEEN[$i]}"
    fi
    i=$((i + 1))
  done

  i=0
  while [ "${i}" -lt "${#HISTORY_KEYS[@]}" ]; do
    key="${HISTORY_KEYS[$i]}"
    seen="${HISTORY_SEEN[$i]}"
    i=$((i + 1))
    [ "${key%%|*}" = "${host}" ] || continue

    ip="${key##*|}"
    append_unique HISTORY_IPS "${ip}"
    append_unique REMOVAL_IPS "${ip}"

    if [ "$((RUN_EPOCH - seen))" -le "${LINGER_SECONDS}" ]; then
      append_unique KEEP_IPS "${ip}"
    elif [ "${resolved}" -eq 0 ] && [ "${seen}" -eq "${newest}" ]; then
      append_unique KEEP_IPS "${ip}"
    fi
  done
}

# Drops every remembered mapping whose host|ip key is not among the arguments.
history_retain_keys() {
  local -a kept_keys kept_seen
  local i=0

  kept_keys=()
  kept_seen=()
  while [ "${i}" -lt "${#HISTORY_KEYS[@]}" ]; do
    if [ "$#" -gt 0 ] && array_contains "${HISTORY_KEYS[$i]}" "$@"; then
      kept_keys+=("${HISTORY_KEYS[$i]}")
      kept_seen+=("${HISTORY_SEEN[$i]}")
    fi
    i=$((i + 1))
  done

  HISTORY_KEYS=()
  HISTORY_SEEN=()
  if [ "${#kept_keys[@]}" -gt 0 ]; then
    HISTORY_KEYS=("${kept_keys[@]}")
    HISTORY_SEEN=("${kept_seen[@]}")
  fi
}

resolve_entry_to_ipv4s() {
  local entry="$1"

  if is_ipv4 "${entry}"; then
    printf '%s\n' "${entry}"
    return 0
  fi

  # The system resolver first: it is what applications use, and it is cached.
  # dig is a second opinion only when that produced nothing usable. Asking both
  # every time doubled the cost of a run for the same answers.
  local answers
  answers="$(dscacheutil -q host -a name "${entry}" 2>/dev/null | awk '/^ip_address: /{print $2}')"
  if ! has_public_answer "${answers}"; then
    answers="${answers}"$'\n'"$(dig +time=2 +tries=1 +short A "${entry}" 2>/dev/null)"
  fi

  printf '%s\n' "${answers}" | awk '
    /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {
      if (!seen[$0]++) {
        print $0
      }
    }
  '
}

has_public_answer() {
  local ip

  while IFS= read -r ip; do
    [ -n "${ip}" ] || continue
    is_public_ipv4 "${ip}" && return 0
  done <<< "$1"

  return 1
}

# Resolves ENTRY at most once per run and leaves the raw answers, one per line,
# in RESOLVED_ANSWERS. Every action walks the server list more than once, and
# with a few dozen hostnames the repeated lookups were what pushed a single
# apply past the LaunchDaemon's 60 second interval. Must be called in the
# current shell, not a subshell, or the cache is lost.
resolve_cached() {
  local entry="$1"
  local i=0

  RESOLVED_ANSWERS=""
  while [ "${i}" -lt "${#RESOLVE_CACHE_HOSTS[@]}" ]; do
    if [ "${RESOLVE_CACHE_HOSTS[$i]}" = "${entry}" ]; then
      RESOLVED_ANSWERS="${RESOLVE_CACHE_ANSWERS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done

  RESOLVED_ANSWERS="$(resolve_entry_to_ipv4s "${entry}")"
  RESOLVE_CACHE_HOSTS+=("${entry}")
  RESOLVE_CACHE_ANSWERS+=("${RESOLVED_ANSWERS}")
}

join_by_comma() {
  local first=1
  local item

  for item in "$@"; do
    if [ "${first}" -eq 1 ]; then
      printf '%s' "${item}"
      first=0
    else
      printf ', %s' "${item}"
    fi
  done
}

# Sets IPV4_CLASS to a description of why IP is not an ordinary public address,
# or to the empty string when it is one. Kept free of subshells because it runs
# for every DNS answer and every history line on every apply.
IPV4_CLASS=""

classify_ipv4() {
  local ip="$1"
  local o1 o2 o3 o4

  IPV4_CLASS=""
  is_ipv4 "${ip}" || return 0

  IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"

  if [ "${o1}" -eq 0 ]; then
    IPV4_CLASS='unspecified or reserved'
  elif [ "${o1}" -eq 127 ]; then
    IPV4_CLASS='loopback'
  elif [ "${o1}" -eq 10 ] || { [ "${o1}" -eq 172 ] && [ "${o2}" -ge 16 ] && [ "${o2}" -le 31 ]; } || { [ "${o1}" -eq 192 ] && [ "${o2}" -eq 168 ]; }; then
    IPV4_CLASS='RFC1918/private'
  elif [ "${o1}" -eq 100 ] && [ "${o2}" -ge 64 ] && [ "${o2}" -le 127 ]; then
    IPV4_CLASS='CGNAT/shared address space'
  elif [ "${o1}" -eq 169 ] && [ "${o2}" -eq 254 ]; then
    IPV4_CLASS='link-local'
  elif [ "${o1}" -ge 224 ] && [ "${o1}" -le 239 ]; then
    IPV4_CLASS='multicast'
  elif [ "${o1}" -eq 255 ] && [ "${o2}" -eq 255 ] && [ "${o3}" -eq 255 ] && [ "${o4}" -eq 255 ]; then
    IPV4_CLASS='broadcast'
  fi

  return 0
}

ipv4_warning_message() {
  classify_ipv4 "$1"
  printf '%s' "${IPV4_CLASS}"
}

is_public_ipv4() {
  is_ipv4 "$1" || return 1
  classify_ipv4 "$1"
  [ -z "${IPV4_CLASS}" ]
}

warn_if_unusual_ipv4() {
  local ip="$1"
  local context="$2"
  local warning_text

  warning_text="$(ipv4_warning_message "${ip}" || true)"
  [ -n "${warning_text}" ] || return 0
  warn "${context}: ${ip} is ${warning_text} and unusual but allowed."
}

log_if_unusual_ipv4() {
  local ip="$1"
  local warning_text

  warning_text="$(ipv4_warning_message "${ip}" || true)"
  [ -n "${warning_text}" ] || return 0
  log "    warning  : ${ip} is ${warning_text} and unusual but allowed."
}

# Verbose, because only the verbose reply carries the route's bound source
# address. The plain "gateway:" and "interface:" lines are unchanged by -v.
#
# The verbose form is not relied on to succeed: if it yields no "interface:"
# line the plain lookup is used instead. That costs only the bound address, and
# callers already treat a missing one as unknown rather than as a mismatch.
get_route_snapshot() {
  local reply

  reply="$(route -n -v get "$1" 2>/dev/null || true)"
  case "${reply}" in
    *interface:*) ;;
    *) reply="$(route -n get "$1" 2>/dev/null || true)" ;;
  esac

  printf '%s\n' "${reply}"
}

route_gateway() {
  printf '%s\n' "$1" | awk -F': ' '/^[[:space:]]*gateway:/{print $2; exit}'
}

route_interface() {
  printf '%s\n' "$1" | awk -F': ' '/^[[:space:]]*interface:/{print $2; exit}'
}

# The address the kernel bound to the route when it was created (RTA_IFA). The
# reply ends with
#   sockaddrs: <DST,GATEWAY,IFP,IFA>
#    203.0.113.10 192.168.1.1 index: 11 en0:aa.bb.cc.dd.ee.ff 192.168.1.42
# and the last field of that last line is the bound address. Prints nothing
# when the reply has no such line, so callers can tell "unknown" from "wrong".
route_source_address() {
  printf '%s\n' "$1" | awk '
    /^sockaddrs: </ { want = ($0 ~ /IFA>[[:space:]]*$/); last = ""; next }
    want && NF > 0 { last = $NF; want = 0 }
    END { if (last ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) print last }
  '
}

# Destinations of static, gatewayed host routes outside any tunnel -- the only
# kind of route this script installs, and so the only kind it will delete.
read_kernel_host_routes() {
  local destination iface

  KERNEL_HOST_ROUTES=()
  while read -r destination iface; do
    [ -n "${destination}" ] || continue
    is_ipv4 "${destination}" || continue
    is_tunnel_interface "${iface}" && continue
    KERNEL_HOST_ROUTES+=("${destination}")
  done < <(
    netstat -rn -f inet 2>/dev/null | awk '$3 ~ /G/ && $3 ~ /H/ && $3 ~ /S/ { print $1, $4 }'
  )
}

read_local_addresses() {
  local address

  LOCAL_ADDRS=()
  while IFS= read -r address; do
    if is_ipv4 "${address}"; then
      LOCAL_ADDRS+=("${address}")
    fi
  done < <(ifconfig 2>/dev/null | awk '/^[[:space:]]*inet /{print $2}')
}

# A target that is one of this Mac's own addresses needs no route, and a host
# route for it would send traffic for the Mac itself out to the router.
is_local_address() {
  [ "${#LOCAL_ADDRS[@]}" -gt 0 ] && array_contains "$1" "${LOCAL_ADDRS[@]}"
}

# Fills, for one configured server:
#
#   CURRENT_IPS   what it resolves to right now (the address itself for IPv4)
#   REJECTED_IPS  DNS answers that were ignored as non-public
#   HISTORY_IPS   every remembered address for the hostname
#   KEEP_IPS      what apply should have routed: CURRENT_IPS plus whatever
#                 history_collect_for_host retains
#   REMOVAL_IPS   CURRENT_IPS plus HISTORY_IPS, for remove
#
# A hostname answer outside public address space is never used. Such answers
# are what a filtering resolver or a captive portal hands out in place of the
# real address (10.10.34.34-36 being the common sinkhole here). Routing one
# does nothing useful, and treating it as the name's current address would let
# the real route lapse. A private address the operator really wants bypassed is
# still accepted as a literal IPv4 line in servers.txt.
collect_entry_targets() {
  local entry="$1"
  local ip
  local resolved=0

  CURRENT_IPS=()
  HISTORY_IPS=()
  REMOVAL_IPS=()
  KEEP_IPS=()
  REJECTED_IPS=()

  if is_ipv4 "${entry}"; then
    CURRENT_IPS=("${entry}")
    REMOVAL_IPS=("${entry}")
    KEEP_IPS=("${entry}")
    return 0
  fi

  resolve_cached "${entry}"
  while IFS= read -r ip; do
    [ -n "${ip}" ] || continue
    is_ipv4 "${ip}" || continue
    if is_public_ipv4 "${ip}"; then
      append_unique CURRENT_IPS "${ip}"
      history_set "${entry}" "${ip}" "${RUN_EPOCH}"
    else
      append_unique REJECTED_IPS "${ip}"
    fi
  done <<< "${RESOLVED_ANSWERS}"

  if [ "${#CURRENT_IPS[@]}" -gt 0 ]; then
    resolved=1
    for ip in "${CURRENT_IPS[@]}"; do
      append_unique KEEP_IPS "${ip}"
      append_unique REMOVAL_IPS "${ip}"
    done
  fi

  history_collect_for_host "${entry}" "${resolved}"
}

merge_history_from_servers() {
  local entry

  read_history_keys

  if [ "${#SERVERS[@]}" -gt 0 ]; then
    for entry in "${SERVERS[@]}"; do
      collect_entry_targets "${entry}"
    done
  fi
}

write_config_with_entry_removed() {
  local target="$1"
  local tmp_file raw trimmed normalized removed=0
  local lines_to_keep=""

  while IFS= read -r raw || [ -n "${raw}" ]; do
    trimmed="$(trim "${raw}")"

    if [ -z "${trimmed}" ] || [[ "${trimmed}" =~ ^# ]]; then
      lines_to_keep="${lines_to_keep}${raw}"$'\n'
      continue
    fi

    normalized="$(normalize_entry "${trimmed}" 2>/dev/null || true)"
    if [ -n "${normalized}" ] && [ "${normalized}" = "${target}" ]; then
      removed=1
      continue
    fi

    lines_to_keep="${lines_to_keep}${raw}"$'\n'
  done < "${CONFIG_FILE}"

  if [ "${removed}" -eq 0 ]; then
    return 1
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_run_log "Would remove ${target} from ${CONFIG_FILE}"
    return 0
  fi

  # mktemp creates the file 0600 and owned by whoever is running. Renaming that
  # over servers.txt as-is silently tightened the list's mode on every delete
  # (and, under sudo, handed it to root), so carry the original's over.
  local mode owner
  mode="$(stat -f '%Lp' "${CONFIG_FILE}" 2>/dev/null || true)"
  owner="$(stat -f '%u:%g' "${CONFIG_FILE}" 2>/dev/null || true)"
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || mode=644

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ssh-bypass-config.XXXXXX")" || return 1
  printf '%s' "${lines_to_keep}" > "${tmp_file}"
  install_state_file "${tmp_file}" "${CONFIG_FILE}" "${mode}" "${owner}" || return 1
}

add_entry_action() {
  local entry="$1"
  local normalized

  [ -f "${CONFIG_FILE}" ] || die "Config file not found: ${CONFIG_FILE}"

  normalized="$(normalize_entry "${entry}" 2>/dev/null || true)"
  if [ -z "${normalized}" ]; then
    warn "Invalid server: ${entry}"
    return 1
  fi

  if is_ipv4 "${normalized}"; then
    warn_if_unusual_ipv4 "${normalized}" "Add server"
  fi

  read_server_list
  if [ "${#SERVERS[@]}" -gt 0 ] && array_contains "${normalized}" "${SERVERS[@]}"; then
    warn "Server already exists: ${normalized}"
    return 1
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_run_log "Would append ${normalized} to ${CONFIG_FILE}"
    return 0
  fi

  # A hand-edited list may lack a final newline; appending straight onto it
  # would fuse the new server with the last one.
  if [ -s "${CONFIG_FILE}" ] && [ -n "$(tail -c 1 "${CONFIG_FILE}" 2>/dev/null)" ]; then
    printf '\n' >> "${CONFIG_FILE}" || return 1
  fi

  printf '%s\n' "${normalized}" >> "${CONFIG_FILE}" || return 1
  log "Added server: ${normalized}"
}

delete_entry_action() {
  local entry="$1"
  local normalized

  [ -f "${CONFIG_FILE}" ] || die "Config file not found: ${CONFIG_FILE}"

  normalized="$(normalize_entry "${entry}" 2>/dev/null || true)"
  if [ -z "${normalized}" ]; then
    warn "Invalid server: ${entry}"
    return 1
  fi

  if write_config_with_entry_removed "${normalized}"; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      dry_run_log "Would delete server: ${normalized}"
    else
      log "Deleted server: ${normalized}"
    fi
    return 0
  fi

  warn "Server not found: ${normalized}"
  return 1
}

delete_entry_by_index() {
  local index="$1"

  read_server_list
  if [ "${#SERVERS[@]}" -eq 0 ]; then
    warn "No servers are configured."
    return 1
  fi

  [[ "${index}" =~ ^[0-9]+$ ]] || {
    warn "Delete choice must be a number."
    return 1
  }

  if [ "${index}" -lt 1 ] || [ "${index}" -gt "${#SERVERS[@]}" ]; then
    warn "Delete choice is out of range."
    return 1
  fi

  delete_entry_action "${SERVERS[$((index - 1))]}"
}

render_ip_line() {
  local label="$1"
  shift

  if [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ -z "${1}" ]; }; then
    log "  ${label}: none"
    return 0
  fi

  log "  ${label}: $(join_by_comma "$@")"
}

log_ip_warning_lines() {
  local label="$1"
  shift
  local ip

  [ "$#" -gt 0 ] || return 0
  for ip in "$@"; do
    [ -n "${ip}" ] || continue
    if [ -n "$(ipv4_warning_message "${ip}" || true)" ]; then
      log "  ${label} warning: ${ip} is $(ipv4_warning_message "${ip}") and unusual but allowed."
    fi
  done
}

view_entries() {
  local index=1 entry ip
  local -a remembered_only

  remembered_only=()
  read_server_list
  merge_history_from_servers

  if [ "${#SERVERS[@]}" -eq 0 ]; then
    log "No configured servers in ${CONFIG_FILE}"
    return 0
  fi

  for entry in "${SERVERS[@]}"; do
    collect_entry_targets "${entry}"
    remembered_only=()

    if [ "$(entry_type "${entry}")" = "hostname" ] && [ "${#HISTORY_IPS[@]}" -gt 0 ]; then
      for ip in "${HISTORY_IPS[@]}"; do
        if [ "${#CURRENT_IPS[@]}" -eq 0 ] || ! array_contains "${ip}" "${CURRENT_IPS[@]}"; then
          remembered_only+=("${ip}")
        fi
      done
    fi

    log "[${index}] ${entry} ($(entry_type "${entry}"))"
    if [ "${#CURRENT_IPS[@]}" -gt 0 ]; then
      render_ip_line "current resolved IPv4" "${CURRENT_IPS[@]}"
      log_ip_warning_lines "current resolved IPv4" "${CURRENT_IPS[@]}"
    else
      render_ip_line "current resolved IPv4"
    fi

    if [ "${#REJECTED_IPS[@]}" -gt 0 ]; then
      render_ip_line "ignored non-public DNS answers" "${REJECTED_IPS[@]}"
    fi

    if [ "$(entry_type "${entry}")" = "hostname" ]; then
      if [ "${#HISTORY_IPS[@]}" -gt 0 ]; then
        render_ip_line "remembered IPv4 history" "${HISTORY_IPS[@]}"
        log_ip_warning_lines "remembered IPv4 history" "${HISTORY_IPS[@]}"
      else
        render_ip_line "remembered IPv4 history"
      fi

      if [ "${#remembered_only[@]}" -gt 0 ]; then
        render_ip_line "remembered-only IPv4" "${remembered_only[@]}"
        log_ip_warning_lines "remembered-only IPv4" "${remembered_only[@]}"
      else
        render_ip_line "remembered-only IPv4"
      fi
    fi

    index=$((index + 1))
  done
}

print_gateway() {
  local gateway_info gateway interface service local_ip tunnels

  gateway_info="$(detect_physical_gateway)" || die "Unable to detect an active physical gateway."
  IFS='|' read -r gateway interface service local_ip <<< "${gateway_info}"

  log "service=${service}"
  log "interface=${interface}"
  log "gateway=${gateway}"
  log "local_ip=${local_ip}"

  tunnels="$(detect_tunnel_interfaces | tr '\n' ' ')"
  tunnels="$(trim "${tunnels}")"
  log "tunnel_interfaces=${tunnels:-none}"

  tunnels="$(ipv6_default_interfaces)"
  log "ipv6_default_interfaces=${tunnels:-none}"
}

# Interfaces carrying a global IPv6 default. This script routes IPv4 only: it
# has nothing to steer IPv6 with, so when one of these exists a server that
# also publishes an AAAA record can be reached over IPv6 by whatever path this
# says, bypass or no bypass. Interface-scoped defaults (flag I), which macOS
# keeps on every utun, are not a usable default and are ignored.
ipv6_default_interfaces() {
  local found

  found="$(
    netstat -rn -f inet6 2>/dev/null | awk '
      ($1 == "default" || $1 == "::/1" || $1 == "8000::/1" || $1 == "2000::/3") \
        && $3 !~ /I/ && $4 != "" { print $4 }
    ' | sort -u | tr '\n' ' '
  )"
  trim "${found}"
}

report_ipv6_exposure() {
  local interfaces

  interfaces="$(ipv6_default_interfaces)"
  if [ -z "${interfaces}" ]; then
    log "IPv6 default     : none (IPv4-only bypass covers all traffic)"
    return 0
  fi

  log "IPv6 default     : ${interfaces}"
  log "  note: bypass routes are IPv4 only. A server with an AAAA record can"
  log "  still be reached over IPv6 through the interface above."
}

save_last_applied_snapshot() {
  write_snapshot_file || die "Failed to write snapshot file: ${SNAPSHOT_FILE}"
}

# True when the route "route get" reported is this run's bypass: right gateway,
# right interface, and bound to the address the interface holds now. An
# unreadable bound address counts as a match here; apply then falls back on the
# snapshot (see apply_routes).
route_is_live_bypass() {
  local current_gateway="$1"
  local current_interface="$2"
  local current_source="$3"
  local gateway="$4"
  local interface="$5"
  local local_ip="$6"

  [ "${current_gateway}" = "${gateway}" ] || return 1
  [ "${current_interface}" = "${interface}" ] || return 1
  [ -z "${current_source}" ] || [ "${current_source}" = "${local_ip}" ]
}

apply_routes() {
  local gateway_info gateway interface service local_ip
  local entry ip snapshot current_gateway current_interface current_source
  local -a kept_keys

  kept_keys=()
  require_root_if_needed
  read_server_list

  # Before anything is resolved or changed: with no physical path there is
  # nothing to route through, and no state should move either.
  gateway_info="$(detect_physical_gateway)" || die "Unable to detect an active physical gateway."
  IFS='|' read -r gateway interface service local_ip <<< "${gateway_info}"

  log "Using service ${service} (${interface}) via gateway ${gateway} with local IP ${local_ip}"

  APPLIED_SOURCE_IP="${local_ip}"
  read_snapshot_file
  read_snapshot_source_ip
  if [ -n "${SNAPSHOT_SOURCE_IP}" ] && [ "${SNAPSHOT_SOURCE_IP}" != "${local_ip}" ]; then
    log "Source address changed ${SNAPSHOT_SOURCE_IP} -> ${local_ip}; rebuilding bypass routes."
  fi

  read_history_keys
  read_local_addresses

  TARGET_IPS=()
  if [ "${#SERVERS[@]}" -gt 0 ]; then
    for entry in "${SERVERS[@]}"; do
      collect_entry_targets "${entry}"

      # Interactive detail only. The daemon would repeat these every minute for
      # as long as a name stays filtered or unresolvable.
      if [ -t 1 ] && [ "${#REJECTED_IPS[@]}" -gt 0 ]; then
        log "Ignoring non-public DNS answer for ${entry}: $(join_by_comma "${REJECTED_IPS[@]}")"
      fi
      if [ -t 1 ] && [ "${#CURRENT_IPS[@]}" -eq 0 ] && [ "${#KEEP_IPS[@]}" -gt 0 ]; then
        log "No usable DNS answer for ${entry}; keeping last known: $(join_by_comma "${KEEP_IPS[@]}")"
      fi

      [ "${#KEEP_IPS[@]}" -gt 0 ] || continue
      for ip in "${KEEP_IPS[@]}"; do
        if is_local_address "${ip}"; then
          if [ -t 1 ]; then
            log "Skipping ${ip}: it is one of this Mac's own addresses."
          fi
          continue
        fi

        append_unique TARGET_IPS "${ip}"
        if [ "$(entry_type "${entry}")" = "hostname" ]; then
          kept_keys+=("${entry}|${ip}")
        fi
      done
    done
  fi

  if [ "${#TARGET_IPS[@]}" -eq 0 ]; then
    log "No current IPv4 targets found in ${CONFIG_FILE}; nothing to apply."
  else
    for ip in "${TARGET_IPS[@]}"; do
      snapshot="$(get_route_snapshot "${ip}")"
      current_gateway="$(route_gateway "${snapshot}")"
      current_interface="$(route_interface "${snapshot}")"
      current_source="$(route_source_address "${snapshot}")"

      # Leave a route alone only when every sign says it is this run's route:
      # right gateway and interface, the snapshot taken under the address the
      # interface still holds, and the route itself bound to that address. If
      # the bound address cannot be read, the route must at least be one the
      # previous apply recorded, so a route of unknown age is never trusted.
      if route_is_live_bypass "${current_gateway}" "${current_interface}" "${current_source}" \
        "${gateway}" "${interface}" "${local_ip}" \
        && [ "${SNAPSHOT_SOURCE_IP}" = "${local_ip}" ] \
        && { [ -n "${current_source}" ] \
          || { [ "${#SNAPSHOT_IPS[@]}" -gt 0 ] && array_contains "${ip}" "${SNAPSHOT_IPS[@]}"; }; }; then
        if [ -t 1 ]; then
          warn_if_unusual_ipv4 "${ip}" "Apply"
          log "Already bypassed: ${ip} -> ${gateway} (${interface})"
        fi
        continue
      fi

      warn_if_unusual_ipv4 "${ip}" "Apply"

      if [ "${DRY_RUN}" -eq 1 ]; then
        dry_run_log "Would delete any existing host route for ${ip}"
        dry_run_log "Would add host route ${ip} via ${gateway}"
        continue
      fi

      # The route added here must be unscoped. A connect() that does not bind a
      # source address resolves against the global table only, and -ifscope
      # routes are excluded from that lookup, so a scoped route never diverts
      # ordinary traffic. Unscoped is also what makes this VPN-agnostic: a /32
      # wins longest-prefix match over WireGuard's and OpenVPN def1's 0/1 and
      # 128.0/1 just as it does over a plain default installed by OpenVPN's
      # redirect-gateway. The scoped delete below clears legacy entries.
      route -n delete -host "${ip}" >/dev/null 2>&1 || true
      route -n delete -host -ifscope "${interface}" "${ip}" >/dev/null 2>&1 || true

      if route -n add -host "${ip}" "${gateway}" >/dev/null 2>&1; then
        log "Applied bypass: ${ip} -> ${gateway} (${interface})"
      else
        warn "Failed to add route for ${ip} via ${gateway}; continuing."
      fi
    done
  fi

  remove_stale_routes "${interface}"

  # Forget mappings that are no longer routed: a deleted server's, and
  # addresses a still-resolving name left more than LINGER_SECONDS ago. Their
  # routes went in remove_stale_routes just above, so nothing is orphaned.
  if [ "${#kept_keys[@]}" -gt 0 ]; then
    history_retain_keys "${kept_keys[@]}"
  else
    history_retain_keys
  fi
  write_history_file_from_keys || die "Failed to write history file: ${HISTORY_FILE}"

  save_last_applied_snapshot
}

# Deletes host routes this script installed earlier for addresses that are no
# longer targets. Without this, apply only ever added: a deleted server kept
# its route until reboot, an address a CDN had rotated away from stayed outside
# the VPN indefinitely, and a route left pointing at a previous network's
# gateway blackholed its destination. It also closes the stale-source hole for
# good -- a route that leaves the target set is removed, so it cannot come back
# later looking valid while still bound to an address the interface has lost.
#
# Candidates are limited to addresses this script has itself recorded (the
# previous snapshot and the history file), and a candidate is touched only if
# the kernel really holds a static host route for it outside any tunnel.
remove_stale_routes() {
  local interface="$1"
  local ip

  STALE_CANDIDATE_IPS=()
  if [ "${#SNAPSHOT_IPS[@]}" -gt 0 ]; then
    for ip in "${SNAPSHOT_IPS[@]}"; do
      append_unique STALE_CANDIDATE_IPS "${ip}"
    done
  fi
  if [ "${#HISTORY_FILE_IPS[@]}" -gt 0 ]; then
    for ip in "${HISTORY_FILE_IPS[@]}"; do
      append_unique STALE_CANDIDATE_IPS "${ip}"
    done
  fi

  [ "${#STALE_CANDIDATE_IPS[@]}" -gt 0 ] || return 0

  read_kernel_host_routes
  [ "${#KERNEL_HOST_ROUTES[@]}" -gt 0 ] || return 0

  for ip in "${STALE_CANDIDATE_IPS[@]}"; do
    if [ "${#TARGET_IPS[@]}" -gt 0 ] && array_contains "${ip}" "${TARGET_IPS[@]}"; then
      continue
    fi
    array_contains "${ip}" "${KERNEL_HOST_ROUTES[@]}" || continue

    if [ "${DRY_RUN}" -eq 1 ]; then
      dry_run_log "Would delete stale host route for ${ip}"
      continue
    fi

    route -n delete -host -ifscope "${interface}" "${ip}" >/dev/null 2>&1 || true
    if route -n delete -host "${ip}" >/dev/null 2>&1; then
      log "Removed stale bypass: ${ip}"
    else
      warn "Failed to remove stale route for ${ip}; continuing."
    fi
  done
}

remove_routes() {
  local entry ip
  local gateway_info gateway interface service local_ip

  require_root_if_needed
  read_server_list
  merge_history_from_servers
  read_snapshot_file

  gateway=""
  interface=""
  service=""
  local_ip=""
  gateway_info="$(detect_physical_gateway)" && \
    IFS='|' read -r gateway interface service local_ip <<< "${gateway_info}"

  TARGET_IPS=()
  if [ "${#SERVERS[@]}" -gt 0 ]; then
    for entry in "${SERVERS[@]}"; do
      collect_entry_targets "${entry}"
      if [ "${#REMOVAL_IPS[@]}" -gt 0 ]; then
        for ip in "${REMOVAL_IPS[@]}"; do
          append_unique TARGET_IPS "${ip}"
        done
      fi
    done
  fi

  # Everything the history file names, whichever server it belonged to and
  # whether or not this version would still remember it.
  if [ "${#HISTORY_FILE_IPS[@]}" -gt 0 ]; then
    for ip in "${HISTORY_FILE_IPS[@]}"; do
      append_unique TARGET_IPS "${ip}"
    done
  fi

  if [ "${#SNAPSHOT_IPS[@]}" -gt 0 ]; then
    for ip in "${SNAPSHOT_IPS[@]}"; do
      append_unique TARGET_IPS "${ip}"
    done
  fi

  if [ "${#TARGET_IPS[@]}" -eq 0 ]; then
    log "No removable IPv4 targets found in ${CONFIG_FILE}, ${HISTORY_FILE}, or ${SNAPSHOT_FILE}; nothing to remove."
    return 0
  fi

  for ip in "${TARGET_IPS[@]}"; do
    warn_if_unusual_ipv4 "${ip}" "Remove"

    if [ "${DRY_RUN}" -eq 1 ]; then
      dry_run_log "Would delete host route for ${ip}"
      continue
    fi

    if [ -n "${interface}" ]; then
      route -n delete -host -ifscope "${interface}" "${ip}" >/dev/null 2>&1 || true
    fi

    if route -n delete -host "${ip}" >/dev/null 2>&1; then
      log "Removed bypass: ${ip}"
    else
      log "No explicit bypass route present: ${ip}"
    fi
  done
}

report_ip_state() {
  local ip="$1"
  local gateway="$2"
  local interface="$3"
  local mode="$4"
  local flavor="$5"
  local local_ip="$6"
  local kind="${7:-}"
  local entry="${8:-}"
  local snapshot current_gateway current_interface current_source state result
  local tsv_state tsv_result

  if is_local_address "${ip}"; then
    log "  ${flavor}: ${ip}"
    log "    state    : this Mac's own address (never routed)"
    tsv_record target "${entry}" "${ip}" "${kind}" local "" "" "" ""
    return 0
  fi

  snapshot="$(get_route_snapshot "${ip}")"
  current_gateway="$(route_gateway "${snapshot}")"
  current_interface="$(route_interface "${snapshot}")"
  current_source="$(route_source_address "${snapshot}")"

  # Gateway and interface alone called a dead route "bypassed": one still bound
  # to an address the interface no longer holds looks perfect on both counts
  # and fails every unbound connect() with EADDRNOTAVAIL.
  if route_is_live_bypass "${current_gateway}" "${current_interface}" "${current_source}" \
    "${gateway}" "${interface}" "${local_ip}"; then
    state="bypassed"
    tsv_state="bypassed"
    result="PASS"
  elif [ "${current_gateway}" = "${gateway}" ] && [ "${current_interface}" = "${interface}" ]; then
    state="stale source address (route bound to ${current_source}, ${interface} now has ${local_ip})"
    tsv_state="stale-source"
    result="FAIL"
  else
    state="vpn/default-route"
    tsv_state="vpn"
    result="FAIL"
  fi

  # Only `test` judges, and it never judges an expired address.
  tsv_result="-"
  [ "${mode}" = "test" ] && tsv_result="${result}"
  tsv_record target "${entry}" "${ip}" "${kind}" "${tsv_state}" "${tsv_result}" \
    "${current_gateway}" "${current_interface}" "${current_source}"

  log "  ${flavor}: ${ip}"
  log "    state    : ${state}"
  log "    gateway  : ${current_gateway:-unknown}"
  log "    interface: ${current_interface:-unknown}"
  log "    source   : ${current_source:-unknown}"
  log_if_unusual_ipv4 "${ip}"

  if [ "${mode}" = "test" ]; then
    log "    result   : ${result}"
    if [ "${result}" = "FAIL" ]; then
      TEST_FAILURES=$((TEST_FAILURES + 1))
    fi
  fi
}

report_routes() {
  local mode="$1"
  local gateway_info gateway interface service local_ip
  local entry ip
  local -a remembered_only snapshot_only

  local resolution entry_result

  remembered_only=()
  snapshot_only=()
  EXPLAINED_IPS=()

  # --tsv: records go to the real stdout through fd 3; the human report below
  # is discarded. Warnings and errors still go to stderr either way.
  if [ "${TSV_OUTPUT}" -eq 1 ]; then
    exec 3>&1 1>/dev/null
  fi
  tsv_record format splitroute-tsv 1 "${mode}"

  read_server_list
  merge_history_from_servers
  read_snapshot_file
  read_local_addresses

  gateway_info="$(detect_physical_gateway)" || die "Unable to detect an active physical gateway."
  IFS='|' read -r gateway interface service local_ip <<< "${gateway_info}"

  if [ "${TSV_OUTPUT}" -eq 1 ]; then
    tsv_record gateway "${service}" "${interface}" "${gateway}" "${local_ip}" \
      "$(trim "$(detect_tunnel_interfaces | tr '\n' ' ')")" \
      "$(ipv6_default_interfaces)"
  fi

  log "Physical service : ${service}"
  log "Physical interface: ${interface}"
  log "Physical gateway : ${gateway}"
  log "Local IP         : ${local_ip}"
  report_ipv6_exposure

  if [ "${#SERVERS[@]}" -eq 0 ]; then
    log ""
    log "No servers configured in ${CONFIG_FILE}"
  else
    log ""
  fi

  if [ "${#SERVERS[@]}" -gt 0 ]; then
    for entry in "${SERVERS[@]}"; do
      collect_entry_targets "${entry}"
      remembered_only=()

      if [ "$(entry_type "${entry}")" = "hostname" ] && [ "${#HISTORY_IPS[@]}" -gt 0 ]; then
        for ip in "${HISTORY_IPS[@]}"; do
          append_unique EXPLAINED_IPS "${ip}"
          if [ "${#CURRENT_IPS[@]}" -eq 0 ] || ! array_contains "${ip}" "${CURRENT_IPS[@]}"; then
            remembered_only+=("${ip}")
          fi
        done
      fi

      if [ "${#CURRENT_IPS[@]}" -gt 0 ]; then
        for ip in "${CURRENT_IPS[@]}"; do
          append_unique EXPLAINED_IPS "${ip}"
        done
      fi

      log "Configured server: ${entry} ($(entry_type "${entry}"))"

      entry_result="-"
      if [ "${#CURRENT_IPS[@]}" -gt 0 ]; then
        resolution="resolved"
      elif [ "${#KEEP_IPS[@]}" -gt 0 ]; then
        resolution="last-known"
      else
        resolution="unresolved"
        if [ "${mode}" = "test" ] && [ "$(entry_type "${entry}")" = "hostname" ]; then
          entry_result="FAIL"
        fi
      fi
      tsv_record entry "${entry}" "$(entry_type "${entry}")" "${resolution}" "${entry_result}"

      if [ "${#CURRENT_IPS[@]}" -eq 0 ]; then
        if [ "${#KEEP_IPS[@]}" -gt 0 ]; then
          # Not a failure: the last known addresses stay routed and are
          # checked one by one below.
          log "  current resolved IPv4: none (no usable DNS answer; last known addresses stay routed)"
        else
          log "  current resolved IPv4: none"
          if [ "${entry_result}" = "FAIL" ]; then
            log "  result               : FAIL (no current IPv4 target)"
            TEST_FAILURES=$((TEST_FAILURES + 1))
          fi
        fi
      else
        for ip in "${CURRENT_IPS[@]}"; do
          report_ip_state "${ip}" "${gateway}" "${interface}" "${mode}" "current resolved IPv4" "${local_ip}" \
            current "${entry}"
        done
      fi

      if [ "${#REJECTED_IPS[@]}" -gt 0 ]; then
        render_ip_line "ignored non-public DNS answers" "${REJECTED_IPS[@]}"
        for ip in "${REJECTED_IPS[@]}"; do
          tsv_record rejected "${entry}" "${ip}"
        done
      fi

      if [ "$(entry_type "${entry}")" = "hostname" ]; then
        if [ "${#HISTORY_IPS[@]}" -gt 0 ]; then
          render_ip_line "remembered IPv4 history" "${HISTORY_IPS[@]}"
        else
          render_ip_line "remembered IPv4 history"
        fi

        if [ "${#remembered_only[@]}" -eq 0 ]; then
          log "  remembered-only IPv4: none"
        else
          for ip in "${remembered_only[@]}"; do
            if [ "${#KEEP_IPS[@]}" -gt 0 ] && array_contains "${ip}" "${KEEP_IPS[@]}"; then
              report_ip_state "${ip}" "${gateway}" "${interface}" "${mode}" "remembered-only IPv4" "${local_ip}" \
                remembered "${entry}"
            else
              # Past its linger window: apply no longer routes it and will
              # forget it on its next run, so it is shown but never judged.
              report_ip_state "${ip}" "${gateway}" "${interface}" "status" "expired IPv4 (no longer routed)" "${local_ip}" \
                expired "${entry}"
            fi
          done
        fi
      fi

      log ""
    done
  fi

  if [ "${#SNAPSHOT_IPS[@]}" -gt 0 ]; then
    for ip in "${SNAPSHOT_IPS[@]}"; do
      if [ "${#EXPLAINED_IPS[@]}" -eq 0 ] || ! array_contains "${ip}" "${EXPLAINED_IPS[@]}"; then
        snapshot_only+=("${ip}")
      fi
    done
  fi

  if [ "${#snapshot_only[@]}" -gt 0 ]; then
    log "Snapshot-only IPv4 targets"
    for ip in "${snapshot_only[@]}"; do
      report_ip_state "${ip}" "${gateway}" "${interface}" "${mode}" "snapshot-only IPv4" "${local_ip}" \
        snapshot-only ""
    done
    log ""
  fi

  # Last record on success. A consumer that never sees it got a truncated run
  # (the script died or was killed part-way) and must not trust the rest.
  if [ "${mode}" = "test" ]; then
    tsv_record summary "${mode}" "${TEST_FAILURES}"
  else
    tsv_record summary "${mode}" ""
  fi
}

show_status() {
  report_routes "status"
}

# Returns 1 when any target failed, so the result is usable from a script.
test_routes() {
  TEST_FAILURES=0
  report_routes "test"

  if [ "${TEST_FAILURES}" -gt 0 ]; then
    log "Test result: ${TEST_FAILURES} FAIL"
    return 1
  fi

  log "Test result: all PASS"
}

# Trims history to what resolves now. A hostname with no usable answer keeps
# its last known addresses: wiping them would drop its bypass at the next
# apply for no better reason than DNS being unavailable when this ran.
prune_history() {
  local entry ip
  local -a kept_keys

  kept_keys=()
  read_server_list
  read_history_keys

  if [ "${#SERVERS[@]}" -gt 0 ]; then
    for entry in "${SERVERS[@]}"; do
      [ "$(entry_type "${entry}")" = "hostname" ] || continue
      collect_entry_targets "${entry}"

      if [ "${#CURRENT_IPS[@]}" -gt 0 ]; then
        for ip in "${CURRENT_IPS[@]}"; do
          kept_keys+=("${entry}|${ip}")
        done
      elif [ "${#KEEP_IPS[@]}" -gt 0 ]; then
        for ip in "${KEEP_IPS[@]}"; do
          kept_keys+=("${entry}|${ip}")
        done
      fi
    done
  fi

  if [ "${#kept_keys[@]}" -gt 0 ]; then
    history_retain_keys "${kept_keys[@]}"
  else
    history_retain_keys
  fi

  write_history_file_from_keys || die "Failed to write history file: ${HISTORY_FILE}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_run_log "Would prune history file: ${HISTORY_FILE}"
  else
    log "Pruned history file: ${HISTORY_FILE}"
  fi
}

discover_ssh_import_candidates() {
  local source_file="$1"
  local alias target normalized_target line warning_text

  [ -f "${source_file}" ] || die "SSH config file not found: ${source_file}"
  IMPORT_KEYS=()

  while IFS='|' read -r alias target || [ -n "${alias}" ] || [ -n "${target}" ]; do
    [ -n "${alias}" ] || continue
    [ -n "${target}" ] || continue

    normalized_target="$(normalize_entry "${target}" 2>/dev/null || true)"
    if [ -z "${normalized_target}" ]; then
      warn "Skipping SSH config host ${alias}: unsupported HostName ${target}"
      continue
    fi

    append_unique IMPORT_KEYS "${alias}|${normalized_target}"
  done < <(
    awk '
      function flush(i) {
        if (host_count == 0 || hostname == "") {
          host_count = 0
          hostname = ""
          return
        }
        for (i = 1; i <= host_count; i++) {
          print hosts[i] "|" hostname
        }
        host_count = 0
        hostname = ""
      }
      /^[[:space:]]*#/ { next }
      {
        key = tolower($1)
      }
      key == "host" {
        flush()
        for (i = 2; i <= NF; i++) {
          token = $i
          if (token ~ /[*?!]/ || token ~ /^!/) {
            continue
          }
          host_count++
          hosts[host_count] = token
        }
        next
      }
      key == "hostname" {
        if (host_count > 0 && hostname == "" && NF >= 2) {
          hostname = $2
        }
        next
      }
      END {
        flush()
      }
    ' "${source_file}"
  )

  if [ "${#IMPORT_KEYS[@]}" -eq 0 ]; then
    log "No importable SSH config targets found in ${source_file}"
    return 0
  fi

  log "Importable SSH config targets from ${source_file}:"
  local index=1
  for line in "${IMPORT_KEYS[@]}"; do
    alias="${line%%|*}"
    target="${line#*|}"
    log "[${index}] ${alias} -> ${target}"
    if is_ipv4 "${target}"; then
      warning_text="$(ipv4_warning_message "${target}" || true)"
      [ -n "${warning_text}" ] && log "    warning: ${target} is ${warning_text} and unusual but allowed."
    fi
    index=$((index + 1))
  done
}

import_keys_by_indices() {
  local selection="$1"
  local normalized_selection index token key target imported_any=0
  local -a tokens

  normalized_selection="$(printf '%s' "${selection}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ -n "${normalized_selection}" ] || {
    warn "No selection entered."
    return 1
  }

  if [ "${normalized_selection}" = "all" ]; then
    if [ "${#IMPORT_KEYS[@]}" -gt 0 ]; then
      for key in "${IMPORT_KEYS[@]}"; do
        target="${key#*|}"
        add_entry_action "${target}" && imported_any=1
      done
    fi
    [ "${imported_any}" -eq 1 ] && return 0
    return 1
  fi

  IFS=',' read -r -a tokens <<< "${normalized_selection}"
  for token in "${tokens[@]}"; do
    [[ "${token}" =~ ^[0-9]+$ ]] || {
      warn "Invalid import selection: ${token}"
      continue
    }

    index="${token}"
    if [ "${index}" -lt 1 ] || [ "${index}" -gt "${#IMPORT_KEYS[@]}" ]; then
      warn "Import selection out of range: ${index}"
      continue
    fi

    key="${IMPORT_KEYS[$((index - 1))]}"
    target="${key#*|}"
    add_entry_action "${target}" && imported_any=1
  done

  [ "${imported_any}" -eq 1 ]
}

import_ssh_config_action() {
  discover_ssh_import_candidates "${SSH_CONFIG_FILE}"

  if [ "${#IMPORT_KEYS[@]}" -eq 0 ]; then
    return 0
  fi

  import_keys_by_indices "all" || warn "No new SSH config targets were imported."
}

menu_import_ssh_config() {
  local selection

  discover_ssh_import_candidates "${SSH_CONFIG_FILE}"
  if [ "${#IMPORT_KEYS[@]}" -eq 0 ]; then
    return 0
  fi

  printf "Enter import selection ('all' or comma-separated numbers): "
  IFS= read -r selection
  import_keys_by_indices "${selection}" || warn "No SSH config targets were imported."
}

render_launchd_plist() {
  local destination="$1"
  local script_file config_path history_path snapshot_path

  [ -f "${PLIST_TEMPLATE_FILE}" ] || die "Launchd template not found: ${PLIST_TEMPLATE_FILE}"

  script_file="$(escape_sed_replacement "${SCRIPT_DIR}/manage-ssh-bypass-routes.sh")"
  config_path="$(escape_sed_replacement "${CONFIG_FILE}")"
  history_path="$(escape_sed_replacement "${HISTORY_FILE}")"
  snapshot_path="$(escape_sed_replacement "${SNAPSHOT_FILE}")"

  sed \
    -e "s|__SCRIPT_FILE__|${script_file}|g" \
    -e "s|__CONFIG_PATH__|${config_path}|g" \
    -e "s|__HISTORY_PATH__|${history_path}|g" \
    -e "s|__SNAPSHOT_PATH__|${snapshot_path}|g" \
    "${PLIST_TEMPLATE_FILE}" > "${destination}"
}

# The daemon appends a line or more to its log on every run and nothing else
# ever trimmed it. launchd reopens the log each time it starts the job, so
# newsyslog can rotate the file without signalling anything (flag N).
install_log_rotation() {
  local tmp_file

  [ -d "$(dirname "${NEWSYSLOG_CONF_PATH}")" ] || return 0

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ssh-bypass-newsyslog.XXXXXX")" || return 1
  {
    printf '# Log rotation for the %s LaunchDaemon.\n' "${LAUNCHD_LABEL}"
    printf '# Installed by manage-ssh-bypass-routes.sh install-launchd.\n'
    printf '# logfilename\t\t\t\t[owner:group]\tmode\tcount\tsize(KB)\twhen\tflags\n'
    printf '%s\troot:wheel\t644\t3\t1024\t*\tJN\n' "${LOG_FILE_PATH}"
  } > "${tmp_file}"

  chown root:wheel "${tmp_file}" || return 1
  chmod 644 "${tmp_file}" || return 1
  mv -f "${tmp_file}" "${NEWSYSLOG_CONF_PATH}"
}

install_launchd() {
  local tmp_file

  require_root_if_needed
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ssh-bypass-launchd.XXXXXX")" || die "Failed to create temporary plist"
  render_launchd_plist "${tmp_file}"
  plutil -lint "${tmp_file}" >/dev/null || die "Generated launchd plist did not pass plutil validation"

  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_run_log "Would render ${PLIST_TEMPLATE_FILE} to ${LAUNCHD_PLIST_PATH}"
    dry_run_log "Would set ownership root:wheel and mode 644 on ${LAUNCHD_PLIST_PATH}"
    dry_run_log "Would install log rotation rule ${NEWSYSLOG_CONF_PATH}"
    dry_run_log "Would bootstrap, enable, and kickstart system/${LAUNCHD_LABEL}"
    rm -f "${tmp_file}"
    return 0
  fi

  install_log_rotation || warn "Could not install log rotation rule ${NEWSYSLOG_CONF_PATH}; continuing."

  cp "${tmp_file}" "${LAUNCHD_PLIST_PATH}" || die "Failed to install launchd plist"
  chown root:wheel "${LAUNCHD_PLIST_PATH}" || die "Failed to chown ${LAUNCHD_PLIST_PATH}"
  chmod 644 "${LAUNCHD_PLIST_PATH}" || die "Failed to chmod ${LAUNCHD_PLIST_PATH}"
  launchctl bootout system "${LAUNCHD_PLIST_PATH}" >/dev/null 2>&1 || true
  launchctl bootstrap system "${LAUNCHD_PLIST_PATH}" || die "Failed to bootstrap ${LAUNCHD_PLIST_PATH}"
  launchctl enable "system/${LAUNCHD_LABEL}" || die "Failed to enable system/${LAUNCHD_LABEL}"
  launchctl kickstart -k "system/${LAUNCHD_LABEL}" || die "Failed to kickstart system/${LAUNCHD_LABEL}"
  rm -f "${tmp_file}"
  log "Installed launchd plist: ${LAUNCHD_PLIST_PATH}"
}

uninstall_launchd() {
  require_root_if_needed

  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_run_log "Would disable and boot out system/${LAUNCHD_LABEL}"
    dry_run_log "Would remove ${LAUNCHD_PLIST_PATH}"
    dry_run_log "Would remove ${NEWSYSLOG_CONF_PATH}"
    return 0
  fi

  launchctl disable "system/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
  launchctl bootout system "${LAUNCHD_PLIST_PATH}" >/dev/null 2>&1 || launchctl bootout "system/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
  rm -f "${LAUNCHD_PLIST_PATH}" || die "Failed to remove ${LAUNCHD_PLIST_PATH}"
  rm -f "${NEWSYSLOG_CONF_PATH}" >/dev/null 2>&1 || true
  log "Removed launchd plist: ${LAUNCHD_PLIST_PATH}"
}

launchd_status() {
  local installed="no"
  local loaded="no"

  [ -f "${LAUNCHD_PLIST_PATH}" ] && installed="yes"
  if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    loaded="yes"
  fi

  log "Launchd label : ${LAUNCHD_LABEL}"
  log "Launchd plist : ${LAUNCHD_PLIST_PATH}"
  log "Installed     : ${installed}"
  log "Loaded        : ${loaded}"
}

menu_add_entry() {
  local value

  printf 'Enter server hostname, IPv4, or URL to add: '
  IFS= read -r value
  [ -n "$(trim "${value}")" ] || {
    warn "No value entered."
    return 1
  }

  add_entry_action "${value}"
}

menu_delete_entry() {
  local choice

  read_server_list
  if [ "${#SERVERS[@]}" -eq 0 ]; then
    warn "No servers are configured."
    return 1
  fi

  view_entries
  printf '\nEnter server number to delete: '
  IFS= read -r choice

  delete_entry_by_index "${choice}"
}

show_menu() {
  local choice

  while :; do
    cat <<'EOF'

macOS SSH WireGuard Bypass
1. View servers
2. Add server
3. Delete server
4. Apply routes
5. Remove routes
6. Status
7. Test
8. Print gateway
9. Prune history
10. Import SSH config
11. Install launchd
12. Uninstall launchd
13. Launchd status
14. Quit
EOF

    printf 'Choose an action [1-14]: '
    IFS= read -r choice

    case "${choice}" in
      1) view_entries ;;
      2) menu_add_entry ;;
      3) menu_delete_entry ;;
      4) run_menu_action "apply" "apply_routes" ;;
      5) run_menu_action "remove" "remove_routes" ;;
      6) show_status ;;
      7) test_routes ;;
      8) print_gateway ;;
      9) prune_history ;;
      10) menu_import_ssh_config ;;
      11) run_menu_action "install-launchd" "install_launchd" ;;
      12) run_menu_action "uninstall-launchd" "uninstall_launchd" ;;
      13) launchd_status ;;
      14|q|quit|exit) break ;;
      *) warn "Invalid menu choice: ${choice}" ;;
    esac
  done
}

ACTION=""
ACTION_VALUE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || die "--config requires a path"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --history)
      [ "$#" -ge 2 ] || die "--history requires a path"
      HISTORY_FILE="$2"
      shift 2
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || die "--snapshot requires a path"
      SNAPSHOT_FILE="$2"
      shift 2
      ;;
    --ssh-config)
      [ "$#" -ge 2 ] || die "--ssh-config requires a path"
      SSH_CONFIG_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --timestamps)
      LOG_TIMESTAMPS=1
      shift
      ;;
    --tsv)
      TSV_OUTPUT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    menu|view|apply|remove|status|test|prune-history|import-ssh-config|install-launchd|uninstall-launchd|launchd-status|print-gateway)
      ACTION="$1"
      shift
      ;;
    add|delete)
      ACTION="$1"
      shift
      [ "$#" -ge 1 ] || die "${ACTION} requires a value"
      ACTION_VALUE="$1"
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[ -n "${ACTION}" ] || ACTION="menu"

if [ "${TSV_OUTPUT}" -eq 1 ]; then
  case "${ACTION}" in
    status|test) ;;
    *) die "--tsv is only supported with status and test" ;;
  esac
fi

if action_requires_root "${ACTION}" && [ "${DRY_RUN}" -ne 1 ] && [ "${EUID}" -ne 0 ]; then
  build_invocation_args "${ACTION}" "${ACTION_VALUE}"
  exec sudo "${SCRIPT_PATH}" "${INVOCATION_ARGS[@]}"
fi

case "${ACTION}" in
  menu)
    show_menu
    ;;
  view)
    view_entries
    ;;
  add)
    add_entry_action "${ACTION_VALUE}" || exit 1
    ;;
  delete)
    delete_entry_action "${ACTION_VALUE}" || exit 1
    ;;
  apply)
    apply_routes
    ;;
  remove)
    remove_routes
    ;;
  status)
    show_status
    ;;
  test)
    test_routes || exit 1
    ;;
  prune-history)
    prune_history
    ;;
  import-ssh-config)
    import_ssh_config_action
    ;;
  install-launchd)
    install_launchd
    ;;
  uninstall-launchd)
    uninstall_launchd
    ;;
  launchd-status)
    launchd_status
    ;;
  print-gateway)
    print_gateway
    ;;
esac
