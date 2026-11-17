#!/usr/bin/env bash
#
# system_health.sh - collect basic host health metrics and flag threshold breaches.
#
# Exit codes (Nagios-style, usable by monitoring tools):
#   0 = healthy, 1 = warning, 2 = critical, 3 = unknown / usage error
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

# ---------- defaults (overridable by flags or environment) ----------
CPU_WARN="${HEALTH_CPU_WARN:-90}"
MEM_WARN="${HEALTH_MEM_WARN:-85}"
DISK_WARN="${HEALTH_DISK_WARN:-80}"
CRIT_MARGIN="${HEALTH_CRIT_MARGIN:-10}"     # critical = warning + margin (capped at 100)
LOG_FILE="${HEALTH_LOG_FILE:-./health_log.txt}"
MAX_LOG_BYTES="${HEALTH_MAX_LOG_BYTES:-1048576}"  # rotate at 1 MiB
KEEP_LOGS="${HEALTH_KEEP_LOGS:-5}"
CPU_SAMPLE_SECONDS="${HEALTH_CPU_SAMPLE_SECONDS:-1}"
WEBHOOK_URL="${HEALTH_WEBHOOK_URL:-}"       # optional Slack/Discord webhook (bonus)
OUTPUT_JSON=false
QUIET=false

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Collects CPU, memory, disk (all mounted filesystems), load average and the top 5
processes by memory, appends a timestamped entry to the log file and prints
[WARNING]/[CRITICAL] messages when a threshold is exceeded.

Options:
  --cpu N          CPU usage warning threshold in % (default: ${CPU_WARN})
  --mem N          Memory usage warning threshold in % (default: ${MEM_WARN})
  --disk N         Disk usage warning threshold in % per filesystem (default: ${DISK_WARN})
  --crit-margin N  Critical = warning + N percentage points (default: ${CRIT_MARGIN})
  --log-file PATH  Log file to append to (default: ${LOG_FILE})
  --max-size BYTES Rotate the log file when it exceeds BYTES (default: ${MAX_LOG_BYTES})
  --keep N         Number of rotated log files to keep (default: ${KEEP_LOGS})
  --json           Print and log the report as a single JSON object
  -q, --quiet      Do not print the report to stdout (log file and exit code only)
  -h, --help       Show this help and exit
  -V, --version    Show version and exit

Environment:
  HEALTH_WEBHOOK_URL  If set, warnings/criticals are POSTed to this Slack/Discord webhook.
  HEALTH_*            Every default above can also be set via HEALTH_<NAME> variables.

Exit codes: 0 healthy, 1 warning, 2 critical, 3 unknown/usage error.

Examples:
  ${SCRIPT_NAME} --disk 80 --cpu 90 --mem 85
  ${SCRIPT_NAME} --json --log-file /var/log/system_health/health_log.txt
USAGE
}

die() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 3; }

is_percent() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 100 )); }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --cpu)         [[ $# -ge 2 ]] || die "--cpu needs a value"; CPU_WARN="$2"; shift 2 ;;
      --mem)         [[ $# -ge 2 ]] || die "--mem needs a value"; MEM_WARN="$2"; shift 2 ;;
      --disk)        [[ $# -ge 2 ]] || die "--disk needs a value"; DISK_WARN="$2"; shift 2 ;;
      --crit-margin) [[ $# -ge 2 ]] || die "--crit-margin needs a value"; CRIT_MARGIN="$2"; shift 2 ;;
      --log-file)    [[ $# -ge 2 ]] || die "--log-file needs a value"; LOG_FILE="$2"; shift 2 ;;
      --max-size)    [[ $# -ge 2 ]] || die "--max-size needs a value"; MAX_LOG_BYTES="$2"; shift 2 ;;
      --keep)        [[ $# -ge 2 ]] || die "--keep needs a value"; KEEP_LOGS="$2"; shift 2 ;;
      --json)        OUTPUT_JSON=true; shift ;;
      -q|--quiet)    QUIET=true; shift ;;
      -h|--help)     usage; exit 0 ;;
      -V|--version)  printf '%s %s\n' "${SCRIPT_NAME}" "${VERSION}"; exit 0 ;;
      *)             usage >&2; die "unknown option: $1" ;;
    esac
  done
  local v
  for v in CPU_WARN MEM_WARN DISK_WARN CRIT_MARGIN; do
    is_percent "${!v}" || die "${v} must be an integer between 0 and 100 (got '${!v}')"
  done
  is_uint "${MAX_LOG_BYTES}" || die "--max-size must be a positive integer"
  if ! is_uint "${KEEP_LOGS}" || (( KEEP_LOGS < 1 )); then die "--keep must be >= 1"; fi
}

crit_of() { local c=$(( $1 + CRIT_MARGIN )); (( c > 100 )) && c=100; printf '%d' "${c}"; }

# ---------- collectors ----------
# CPU usage from two /proc/stat samples (more accurate than parsing `top`).
cpu_usage() {
  local -a a b
  read -r -a a < <(grep '^cpu ' /proc/stat)
  sleep "${CPU_SAMPLE_SECONDS}"
  read -r -a b < <(grep '^cpu ' /proc/stat)
  # fields: cpu user nice system idle iowait irq softirq steal
  local idle_a=$(( a[4] + a[5] )) idle_b=$(( b[4] + b[5] ))
  local total_a=0 total_b=0 i
  for i in 1 2 3 4 5 6 7 8; do
    total_a=$(( total_a + a[i] )); total_b=$(( total_b + b[i] ))
  done
  local dt=$(( total_b - total_a )) di=$(( idle_b - idle_a ))
  (( dt > 0 )) || { printf '0.0'; return; }
  awk -v dt="${dt}" -v di="${di}" 'BEGIN { printf "%.1f", (dt - di) * 100 / dt }'
}

# Memory usage = (MemTotal - MemAvailable) / MemTotal, matching what `free` reports as used.
mem_usage() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
       END { if (t > 0) printf "%.1f %d %d", (t - a) * 100 / t, (t - a) / 1024, t / 1024; else print "0 0 0" }' /proc/meminfo
}

load_average() { awk '{ printf "%s %s %s", $1, $2, $3 }' /proc/loadavg; }

# All real mounted filesystems (pseudo/tmpfs/overlay excluded): "mount<TAB>use%<TAB>size<TAB>used"
disk_usage() {
  df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x proc -x sysfs 2>/dev/null \
    | awk 'NR > 1 && $2 > 0 { gsub("%", "", $5); printf "%s\t%s\t%d\t%d\n", $6, $5, $2 / 1024, $3 / 1024 }' \
    | sort -u
}

# Top 5 processes by memory: "pid<TAB>%mem<TAB>rss_mb<TAB>command"
top_processes() {
  ps -eo pid=,pmem=,rss=,comm= --sort=-rss 2>/dev/null \
    | head -n 5 \
    | awk '{ printf "%s\t%s\t%.1f\t%s\n", $1, $2, $3 / 1024, $4 }'
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}

# ---------- log rotation ----------
rotate_log() {
  [[ -f "${LOG_FILE}" ]] || return 0
  local size
  size=$(wc -c < "${LOG_FILE}")
  (( size >= MAX_LOG_BYTES )) || return 0
  local i
  rm -f "${LOG_FILE}.${KEEP_LOGS}"
  for (( i = KEEP_LOGS - 1; i >= 1; i-- )); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$(( i + 1 ))"
  done
  mv -f "${LOG_FILE}" "${LOG_FILE}.1"
}

notify_webhook() {
  [[ -n "${WEBHOOK_URL}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local text="$1" payload
  payload=$(printf '{"text":"%s","content":"%s"}' "$(json_escape "${text}")" "$(json_escape "${text}")")
  # Never let an alerting failure break the health check itself.
  curl -fsS -m 5 -H 'Content-Type: application/json' -d "${payload}" "${WEBHOOK_URL}" >/dev/null 2>&1 || true
}

main() {
  parse_args "$@"

  local ts host
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  host=$(hostname 2>/dev/null || uname -n)

  local cpu mem_pct mem_used mem_total load1 load5 load15
  cpu=$(cpu_usage)
  read -r mem_pct mem_used mem_total <<< "$(mem_usage)"
  read -r load1 load5 load15 <<< "$(load_average)"

  local -a disks procs messages=()
  mapfile -t disks < <(disk_usage)
  mapfile -t procs < <(top_processes)

  local status=0   # 0 ok, 1 warning, 2 critical

  # check <name> <value> <warn-threshold>
  check() {
    local name="$1" value="$2" warn="$3" crit int
    crit=$(crit_of "${warn}")
    int=${value%.*}
    if (( int >= crit )); then
      messages+=("[CRITICAL] ${name} usage ${value}% >= ${crit}% (critical threshold)")
      status=2
    elif (( int >= warn )); then
      messages+=("[WARNING] ${name} usage ${value}% >= ${warn}% (warning threshold)")
      (( status < 1 )) && status=1
    fi
    return 0
  }

  check "CPU" "${cpu}" "${CPU_WARN}"
  check "Memory" "${mem_pct}" "${MEM_WARN}"
  local d mount pct
  for d in "${disks[@]}"; do
    IFS=$'\t' read -r mount pct _ _ <<< "${d}"
    check "Disk ${mount}" "${pct}" "${DISK_WARN}"
  done

  local -a state_names=(OK WARNING CRITICAL)
  local state="${state_names[status]}"
  local report

  if [[ "${OUTPUT_JSON}" == true ]]; then
    local disk_json="" proc_json="" msg_json="" sep size used pid pmem rss cmd m
    sep=""
    for d in "${disks[@]}"; do
      IFS=$'\t' read -r mount pct size used <<< "${d}"
      disk_json+="${sep}{\"mount\":\"$(json_escape "${mount}")\",\"used_percent\":${pct},\"size_mb\":${size},\"used_mb\":${used}}"
      sep=","
    done
    sep=""
    for d in "${procs[@]}"; do
      IFS=$'\t' read -r pid pmem rss cmd <<< "${d}"
      proc_json+="${sep}{\"pid\":${pid},\"mem_percent\":${pmem},\"rss_mb\":${rss},\"command\":\"$(json_escape "${cmd}")\"}"
      sep=","
    done
    sep=""
    for m in "${messages[@]}"; do
      msg_json+="${sep}\"$(json_escape "${m}")\""; sep=","
    done
    report=$(printf '{"timestamp":"%s","host":"%s","status":"%s","exit_code":%d,"cpu_percent":%s,"memory":{"used_percent":%s,"used_mb":%s,"total_mb":%s},"load_average":{"1m":%s,"5m":%s,"15m":%s},"disks":[%s],"top_processes":[%s],"thresholds":{"cpu":%d,"mem":%d,"disk":%d,"critical_margin":%d},"messages":[%s]}' \
      "${ts}" "$(json_escape "${host}")" "${state}" "${status}" "${cpu}" "${mem_pct}" "${mem_used}" "${mem_total}" \
      "${load1}" "${load5}" "${load15}" "${disk_json}" "${proc_json}" \
      "${CPU_WARN}" "${MEM_WARN}" "${DISK_WARN}" "${CRIT_MARGIN}" "${msg_json}")
  else
    report="===== ${ts} host=${host} status=${state} ====="$'\n'
    report+="CPU usage     : ${cpu}%"$'\n'
    report+="Memory usage  : ${mem_pct}% (${mem_used} MiB / ${mem_total} MiB)"$'\n'
    report+="Load average  : ${load1} ${load5} ${load15} (1m 5m 15m)"$'\n'
    report+="Disk usage    :"$'\n'
    for d in "${disks[@]}"; do
      IFS=$'\t' read -r mount pct size used <<< "${d}"
      report+="$(printf '  %-28s %3s%%  (%s MiB / %s MiB)' "${mount}" "${pct}" "${used}" "${size}")"$'\n'
    done
    report+="Top 5 processes by memory:"$'\n'
    report+="$(printf '  %-8s %-6s %-9s %s' PID %MEM RSS_MiB COMMAND)"$'\n'
    for d in "${procs[@]}"; do
      IFS=$'\t' read -r pid pmem rss cmd <<< "${d}"
      report+="$(printf '  %-8s %-6s %-9s %s' "${pid}" "${pmem}" "${rss}" "${cmd}")"$'\n'
    done
    local m
    for m in "${messages[@]}"; do report+="${m}"$'\n'; done
    report="${report%$'\n'}"
  fi

  # Append to the log (rotate first so a single entry is never split across files).
  mkdir -p "$(dirname -- "${LOG_FILE}")"
  rotate_log
  printf '%s\n' "${report}" >> "${LOG_FILE}"

  if [[ "${QUIET}" != true ]]; then
    printf '%s\n' "${report}"
  fi
  # Warnings also go to stderr so they are visible even with --json piped into jq.
  if (( ${#messages[@]} > 0 )); then
    printf '%s\n' "${messages[@]}" >&2
    notify_webhook "$(printf '%s %s on %s\n%s' "${state}" "${ts}" "${host}" "$(printf '%s\n' "${messages[@]}")")"
  fi

  return "${status}"
}

main "$@"
