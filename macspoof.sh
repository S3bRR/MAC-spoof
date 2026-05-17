#!/usr/bin/env zsh
# Lightweight MAC address utility for macOS and Linux.
# No telemetry, no network calls, no third-party dependencies.

emulate -R zsh
setopt pipefail

VERSION="0.1.0"
OS_NAME="$(uname -s 2>/dev/null)"

print_usage() {
  cat <<'EOF'
macspoof - lightweight MAC address utility for macOS and Linux

Usage:
  ./macspoof.sh list
  ./macspoof.sh list-raw
  ./macspoof.sh status <interface>
  ./macspoof.sh current <interface>
  ./macspoof.sh generate
  ./macspoof.sh save-original <interface>
  sudo ./macspoof.sh set <interface> <mac>
  sudo ./macspoof.sh random <interface>
  sudo ./macspoof.sh rotate <interface> <minutes> [count]
  sudo ./macspoof.sh restore <interface>
  ./macspoof.sh forget <interface>

Commands:
  list                  List physical/network interfaces in a compact table.
  list-raw              Print raw OS interface details.
  status <iface>        Show current MAC, saved original MAC, IP, and status.
  current <iface>       Print current live MAC for one interface.
  generate              Print a random unicast locally administered MAC.
  save-original <iface> Save current MAC for later restore.
  set <iface> <mac>     Set a validated custom MAC and verify it.
  random <iface>        Generate, set, and verify a random MAC.
  rotate <iface> <min>  Rotate to a new random MAC every N minutes.
  restore <iface>       Restore saved original MAC and verify it.
  forget <iface>        Remove saved original MAC from local state.
  version               Print version.
  help                  Show this help.

State:
  Restore state is stored locally at ~/.macspoof/originals.tsv by default.
  Override with MACSPOOF_STATE_DIR=/path/to/state.

Notes:
  Network write commands require root because macOS and Linux restrict changes.
  This tool does not send data anywhere and does not write state into this repo.
EOF
}

die() {
  print -u2 -- "error: $*"
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  have_cmd "$1" || die "required command not found: $1"
}

require_supported_os() {
  case "$OS_NAME" in
    Darwin|Linux) return 0 ;;
    *) die "unsupported OS: ${OS_NAME:-unknown}. Supported: macOS/Darwin and Linux." ;;
  esac
}

require_root() {
  if (( EUID != 0 )); then
    die "network write command requires root. Re-run with sudo."
  fi
}

validate_iface_name() {
  local iface="$1"
  [[ -n "$iface" ]] || die "interface name is required"
  [[ "$iface" != -* ]] || die "invalid interface name: $iface"
  [[ "$iface" =~ '^[A-Za-z0-9_.:-]+$' ]] || die "invalid interface name: $iface"
}

validate_positive_int() {
  local name="$1" value="$2" max="${3:-}"
  [[ "$value" =~ '^[0-9]+$' ]] || die "$name must be a positive integer"
  (( value > 0 )) || die "$name must be greater than zero"
  if [[ -n "$max" ]]; then
    (( value <= max )) || die "$name must be $max or less"
  fi
}

state_dir() {
  if [[ -n "${MACSPOOF_STATE_DIR:-}" ]]; then
    print -r -- "$MACSPOOF_STATE_DIR"
    return 0
  fi

  local user_home=""
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    if have_cmd getent; then
      user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | awk -F: '{print $6; exit}')"
    elif have_cmd dscl; then
      user_home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}')"
    fi
  fi

  if [[ -n "$user_home" && -d "$user_home" ]]; then
    print -r -- "$user_home/.macspoof"
  else
    print -r -- "$HOME/.macspoof"
  fi
}

state_file() {
  print -r -- "$(state_dir)/originals.tsv"
}

ensure_state_dir() {
  local dir
  dir="$(state_dir)"
  umask 077
  mkdir -p "$dir" || die "could not create state directory: $dir"
  chmod 700 "$dir" 2>/dev/null || true
}

normalize_mac() {
  local mac="${1:l}"
  mac="${mac//-/:}"

  if [[ "$mac" =~ '^[0-9a-f]{12}$' ]]; then
    mac="${mac[1,2]}:${mac[3,4]}:${mac[5,6]}:${mac[7,8]}:${mac[9,10]}:${mac[11,12]}"
  fi

  [[ "$mac" =~ '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' ]] || return 1
  print -r -- "$mac"
}

validate_mac() {
  local mac first
  mac="$(normalize_mac "$1")" || return 1
  first=$(( 16#${mac[1,2]} ))

  (( first == 255 )) && return 1
  [[ "$mac" == "ff:ff:ff:ff:ff:ff" ]] && return 1
  (( (first & 1) == 0 )) || return 1

  print -r -- "$mac"
}

generate_mac() {
  need_cmd od
  need_cmd tr

  local hex first
  hex="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  [[ "$hex" =~ '^[0-9a-f]{12}$' ]] || die "could not read random bytes"

  first=$(( (16#${hex[1,2]} & 254) | 2 ))
  printf "%02x:%s:%s:%s:%s:%s\n" "$first" "${hex[3,4]}" "${hex[5,6]}" "${hex[7,8]}" "${hex[9,10]}" "${hex[11,12]}"
}

macos_current_mac() {
  need_cmd ifconfig
  local iface="$1" mac
  mac="$(ifconfig "$iface" 2>/dev/null | awk '/^[[:space:]]*ether[[:space:]]/ {print tolower($2); exit}')"
  [[ -n "$mac" ]] || return 1
  print -r -- "$mac"
}

linux_current_mac() {
  local iface="$1" mac=""
  need_cmd ip
  mac="$(ip -o link show dev "$iface" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "link/ether") {print tolower($(i + 1)); exit}}')"
  [[ -n "$mac" ]] || return 1
  print -r -- "$mac"
}

current_mac() {
  case "$OS_NAME" in
    Darwin) macos_current_mac "$1" ;;
    Linux) linux_current_mac "$1" ;;
  esac
}

macos_current_ip() {
  need_cmd ifconfig
  local iface="$1" ip
  ip="$(ifconfig "$iface" 2>/dev/null | awk '/^[[:space:]]*inet[[:space:]]/ && $2 != "127.0.0.1" {print $2; exit}')"
  [[ -n "$ip" ]] && print -r -- "$ip" || print -r -- "-"
}

linux_current_ip() {
  local iface="$1" ip=""
  need_cmd ip
  ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')"
  [[ -n "$ip" ]] && print -r -- "$ip" || print -r -- "-"
}

current_ip() {
  case "$OS_NAME" in
    Darwin) macos_current_ip "$1" ;;
    Linux) linux_current_ip "$1" ;;
  esac
}

macos_status() {
  need_cmd ifconfig
  local iface="$1" link_state
  link_state="$(ifconfig "$iface" 2>/dev/null | awk -F': ' '/status: / {print $2; exit}')"
  [[ -n "$link_state" ]] && print -r -- "$link_state" || print -r -- "-"
}

linux_status() {
  need_cmd ip
  local iface="$1" flags link_state="-"
  flags="$(ip -o link show dev "$iface" 2>/dev/null | awk -F'[<>]' 'NF >= 2 {print $2; exit}')"
  if [[ "$flags" == *"LOWER_UP"* || "$flags" == *"UP"* ]]; then
    link_state="active"
  elif [[ -n "$flags" ]]; then
    link_state="inactive"
  fi
  print -r -- "$link_state"
}

iface_status() {
  case "$OS_NAME" in
    Darwin) macos_status "$1" ;;
    Linux) linux_status "$1" ;;
  esac
}

macos_list() {
  need_cmd networksetup
  need_cmd ifconfig

  printf "%-10s %-30s %-18s %-15s %s\n" "DEVICE" "PORT" "MAC" "IP" "STATUS"

  local line port="" device="" hwmac="" mac ip link_state
  while IFS= read -r line; do
    case "$line" in
      "Hardware Port: "*)
        port="${line#Hardware Port: }"
        ;;
      "Device: "*)
        device="${line#Device: }"
        ;;
      "Ethernet Address: "*)
        hwmac="${line#Ethernet Address: }"
        if [[ -n "$device" && "$device" != "N/A" && "$hwmac" != "N/A" ]]; then
          mac="$(current_mac "$device" 2>/dev/null || true)"
          ip="$(current_ip "$device" 2>/dev/null || print -r -- "-")"
          link_state="$(iface_status "$device" 2>/dev/null || print -r -- "-")"
          [[ -n "$mac" ]] || mac="$hwmac"
          printf "%-10s %-30s %-18s %-15s %s\n" "$device" "$port" "$mac" "$ip" "$link_state"
        fi
        port=""
        device=""
        hwmac=""
        ;;
    esac
  done < <(networksetup -listallhardwareports)
}

linux_list() {
  need_cmd ip
  printf "%-16s %-18s %-15s %s\n" "DEVICE" "MAC" "IP" "STATUS"

  local iface mac ip link_state
  for iface in ${(f)"$(ip -o link show 2>/dev/null | awk -F': ' '{split($2, a, "@"); print a[1]}')"}; do
    [[ "$iface" == "lo" ]] && continue
    mac="$(current_mac "$iface" 2>/dev/null || true)"
    [[ -n "$mac" && "$mac" != "00:00:00:00:00:00" ]] || continue
    ip="$(current_ip "$iface" 2>/dev/null || print -r -- "-")"
    link_state="$(iface_status "$iface" 2>/dev/null || print -r -- "-")"
    printf "%-16s %-18s %-15s %s\n" "$iface" "$mac" "$ip" "$link_state"
  done
}

list_interfaces() {
  case "$OS_NAME" in
    Darwin) macos_list ;;
    Linux) linux_list ;;
  esac
}

raw_list_interfaces() {
  case "$OS_NAME" in
    Darwin)
      need_cmd ifconfig
      ifconfig -a
      ;;
    Linux)
      need_cmd ip
      ip addr show
      ;;
  esac
}

saved_original() {
  local iface="$1" file
  file="$(state_file)"
  [[ -r "$file" ]] || return 1
  awk -F '\t' -v os="$OS_NAME" -v iface="$iface" '$1 == os && $2 == iface {mac = $3} END {if (mac != "") print mac; else exit 1}' "$file"
}

save_original_value() {
  local iface="$1" mac="$2" file tmp now
  ensure_state_dir
  file="$(state_file)"
  tmp="${file}.$$"
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  touch "$file" || die "could not write state file: $file"
  chmod 600 "$file" 2>/dev/null || true

  awk -F '\t' -v os="$OS_NAME" -v iface="$iface" 'BEGIN {OFS = FS} !($1 == os && $2 == iface) {print}' "$file" > "$tmp" \
    || die "could not update state file"
  printf "%s\t%s\t%s\t%s\n" "$OS_NAME" "$iface" "$mac" "$now" >> "$tmp" \
    || die "could not update state file"
  mv "$tmp" "$file" || die "could not replace state file"
  chmod 600 "$file" 2>/dev/null || true
}

forget_original() {
  local iface="$1" file tmp
  file="$(state_file)"
  [[ -r "$file" ]] || return 0
  tmp="${file}.$$"
  awk -F '\t' -v os="$OS_NAME" -v iface="$iface" 'BEGIN {OFS = FS} !($1 == os && $2 == iface) {print}' "$file" > "$tmp" \
    || die "could not update state file"
  mv "$tmp" "$file" || die "could not replace state file"
  chmod 600 "$file" 2>/dev/null || true
}

save_original_command() {
  local iface="$1" mac
  validate_iface_name "$iface"
  mac="$(current_mac "$iface")" || die "could not read current MAC for interface: $iface"
  save_original_value "$iface" "$mac"
  print -r -- "saved original for $iface: $mac"
}

ensure_original_saved() {
  local iface="$1" current existing
  validate_iface_name "$iface"
  existing="$(saved_original "$iface" 2>/dev/null || true)"
  [[ -n "$existing" ]] && return 0

  current="$(current_mac "$iface")" || die "could not read current MAC for interface: $iface"
  save_original_value "$iface" "$current"
  print -r -- "saved original for $iface: $current"
}

macos_set_mac() {
  need_cmd ifconfig
  local iface="$1" mac="$2"

  ifconfig "$iface" down >/dev/null 2>&1 || return 1
  if ifconfig "$iface" ether "$mac" >/dev/null 2>&1; then
    ifconfig "$iface" up >/dev/null 2>&1 || return 1
    return 0
  fi

  ifconfig "$iface" up >/dev/null 2>&1 || true
  return 1
}

linux_set_mac() {
  need_cmd ip
  local iface="$1" mac="$2"

  ip link set dev "$iface" down || return 1
  if ! ip link set dev "$iface" address "$mac"; then
    ip link set dev "$iface" up >/dev/null 2>&1 || true
    return 1
  fi
  ip link set dev "$iface" up || return 1
  return 0
}

backend_set_mac() {
  case "$OS_NAME" in
    Darwin) macos_set_mac "$1" "$2" ;;
    Linux) linux_set_mac "$1" "$2" ;;
  esac
}

apply_mac() {
  local iface="$1" requested="$2" mac current after
  validate_iface_name "$iface"
  mac="$(validate_mac "$requested")" || die "invalid MAC. Use a unicast address like 02:11:22:33:44:55."
  current="$(current_mac "$iface")" || die "interface not found or has no MAC address: $iface"

  ensure_original_saved "$iface"

  print -r -- "current: $current"
  print -r -- "target:  $mac"

  backend_set_mac "$iface" "$mac" || die "failed to set MAC on $iface"

  sleep "${MACSPOOF_VERIFY_DELAY:-1}"
  after="$(current_mac "$iface" 2>/dev/null || true)"
  if [[ "$after" == "$mac" ]]; then
    print -r -- "verified: $iface is now $after"
  else
    die "verification failed. Requested $mac but live MAC is ${after:-unknown}."
  fi
}

restore_mac() {
  local iface="$1" original after
  validate_iface_name "$iface"
  original="$(saved_original "$iface")" || die "no saved original for $iface. Run save-original before spoofing."
  print -r -- "restoring $iface to $original"

  backend_set_mac "$iface" "$original" || die "failed to restore MAC on $iface"

  sleep "${MACSPOOF_VERIFY_DELAY:-1}"
  after="$(current_mac "$iface" 2>/dev/null || true)"
  if [[ "$after" == "$original" ]]; then
    print -r -- "verified: $iface restored to $after"
  else
    die "restore verification failed. Expected $original but live MAC is ${after:-unknown}."
  fi
}

rotate_mac() {
  local iface="$1" minutes="$2" count="${3:-}" delay iteration=0
  validate_iface_name "$iface"
  validate_positive_int "minutes" "$minutes" 10080
  if [[ -n "$count" ]]; then
    validate_positive_int "count" "$count" 100000
  fi

  delay="${MACSPOOF_ROTATE_SECONDS:-$(( minutes * 60 ))}"
  validate_positive_int "rotation delay seconds" "$delay" 604800

  print -r -- "rotating $iface every $minutes minute(s)"
  if [[ -n "$count" ]]; then
    print -r -- "rotation count: $count"
  else
    print -r -- "rotation count: unlimited; press Ctrl-C to stop"
  fi

  while true; do
    iteration=$(( iteration + 1 ))
    print -r -- "rotation $iteration"
    apply_mac "$iface" "$(generate_mac)"

    if [[ -n "$count" && "$iteration" -ge "$count" ]]; then
      break
    fi

    sleep "$delay"
  done
}

status_command() {
  local iface="$1" mac ip link_state original
  validate_iface_name "$iface"
  mac="$(current_mac "$iface")" || die "interface not found or has no MAC address: $iface"
  ip="$(current_ip "$iface" 2>/dev/null || print -r -- "-")"
  link_state="$(iface_status "$iface" 2>/dev/null || print -r -- "-")"
  original="$(saved_original "$iface" 2>/dev/null || print -r -- "-")"

  print -r -- "interface:      $iface"
  print -r -- "current mac:    $mac"
  print -r -- "saved original: $original"
  print -r -- "ip address:     $ip"
  print -r -- "status:         $link_state"
}

main() {
  require_supported_os

  local command="${1:-help}"
  shift 2>/dev/null || true

  case "$command" in
    help|-h|--help)
      print_usage
      ;;
    version|-v|--version)
      print -r -- "$VERSION"
      ;;
    list|-l|--list)
      list_interfaces
      ;;
    list-raw|list-all|--list-raw|--list-all)
      raw_list_interfaces
      ;;
    status)
      [[ $# -eq 1 ]] || die "usage: ./macspoof.sh status <interface>"
      status_command "$1"
      ;;
    current)
      [[ $# -eq 1 ]] || die "usage: ./macspoof.sh current <interface>"
      validate_iface_name "$1"
      current_mac "$1" || die "interface not found or has no MAC address: $1"
      ;;
    generate)
      generate_mac
      ;;
    save-original)
      [[ $# -eq 1 ]] || die "usage: ./macspoof.sh save-original <interface>"
      save_original_command "$1"
      ;;
    set)
      [[ $# -eq 2 ]] || die "usage: sudo ./macspoof.sh set <interface> <mac>"
      require_root
      apply_mac "$1" "$2"
      ;;
    random)
      [[ $# -eq 1 ]] || die "usage: sudo ./macspoof.sh random <interface>"
      require_root
      apply_mac "$1" "$(generate_mac)"
      ;;
    rotate)
      [[ $# -eq 2 || $# -eq 3 ]] || die "usage: sudo ./macspoof.sh rotate <interface> <minutes> [count]"
      require_root
      rotate_mac "$@"
      ;;
    restore)
      [[ $# -eq 1 ]] || die "usage: sudo ./macspoof.sh restore <interface>"
      require_root
      restore_mac "$1"
      ;;
    forget)
      [[ $# -eq 1 ]] || die "usage: ./macspoof.sh forget <interface>"
      validate_iface_name "$1"
      forget_original "$1"
      print -r -- "forgot saved original for $1"
      ;;
    *)
      print_usage
      die "unknown command: $command"
      ;;
  esac
}

if [[ "${MACSPOOF_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
