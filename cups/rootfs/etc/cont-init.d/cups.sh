#!/usr/bin/with-contenv bash

if [ -f /usr/lib/bashio/bashio.sh ]; then
  # shellcheck source=/dev/null
  source /usr/lib/bashio/bashio.sh
fi

BACKEND_DIR=""
POWER_WRAPPED_BACKENDS="socket ipp ipps lpd usb dnssd"
POWER_LOG_FILE="/data/cups/logs/power-wrapper.log"
STARTUP_LOG_FILE="/data/cups/logs/startup.log"
POWER_STATE_FILE="/data/cups/config/.ha_power_state"
POWER_TOKEN_FILE="/data/cups/config/.ha_supervisor_token"

log_startup() {
  local message="$1"
  echo "[power-hook] ${message}"
  echo "[power-hook] ${message}" >> "${STARTUP_LOG_FILE}" 2>/dev/null || true
}

read_option_bool() {
  local key="$1"
  local default_value="$2"
  local value

  value=$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" /data/options.json 2>/dev/null | head -n1)
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "${default_value}"
  fi
}

read_option_int() {
  local key="$1"
  local default_value="$2"
  local value

  value=$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p" /data/options.json 2>/dev/null | head -n1)
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "${default_value}"
  fi
}

read_option_str() {
  local key="$1"
  local default_value="$2"
  local value

  value=$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" /data/options.json 2>/dev/null | head -n1)
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "${default_value}"
  fi
}

install_power_wrapper() {
  local backend="$1"
  local target="${BACKEND_DIR}/${backend}"
  local real="${BACKEND_DIR}/${backend}.real"

  if [ ! -e "${target}" ] && [ ! -e "${real}" ]; then
    return 2
  fi

  if [ -e "${target}" ] && [ ! -e "${real}" ]; then
    mv "${target}" "${real}"
  fi

  cat > "${target}" << EOF
#!/usr/bin/env bash
set -euo pipefail

BACKEND_REAL="${real}"
POWER_LOG_FILE="${POWER_LOG_FILE}"
POWER_STATE_FILE="${POWER_STATE_FILE}"
POWER_TOKEN_FILE="${POWER_TOKEN_FILE}"
STARTUP_LOG_FILE="${STARTUP_LOG_FILE}"
BOOT_COUNT_FILE="/data/cups/config/.boot_count"

log_msg() {
  local message="\${1:-}"
  local now
  now="\$(date -Iseconds 2>/dev/null || date)"
  mkdir -p "\$(dirname "\${POWER_LOG_FILE}")" >/dev/null 2>&1 || true
  echo "\${now} [power-hook-wrapper] \${message}" >> "\${POWER_LOG_FILE}" 2>/dev/null || true
  if [ -w /proc/1/fd/1 ]; then
    echo "\${now} [power-hook-wrapper] \${message}" >> /proc/1/fd/1 2>/dev/null || true
  fi
}

power_on_switch() {
  # NOTE: entity_id/delay/token are deliberately NOT read from environment
  # variables here. cupsd runs backends with a security-sanitized
  # environment and does not pass through arbitrary variables set by
  # cont-init.d scripts (confirmed: even SUPERVISOR_TOKEN, a real
  # container-level env var, was empty inside this wrapper). Instead, read
  # the values directly from files written by cont-init.d at startup.
  local entity_id=""
  local delay="0"
  local token=""
  local job_id="\${1:-unknown}"

  if [ -f "\${POWER_STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "\${POWER_STATE_FILE}"
    entity_id="\${HA_POWER_SWITCH_ENTITY_ID:-}"
    delay="\${HA_POWER_ON_DELAY:-0}"
  fi
  if [ -f "\${POWER_TOKEN_FILE}" ]; then
    token="\$(cat "\${POWER_TOKEN_FILE}" 2>/dev/null || true)"
  fi

  log_msg "job=\${job_id} power_on_switch invoked entity=\${entity_id:-<empty>} delay=\${delay} token_present=\$([ -n "\${token}" ] && echo yes || echo no)"
  # DIAGNOSTIC: same non-secret-leaking fingerprint format as the boot-time
  # self-check, so the two can be diff'd directly to prove/disprove whether
  # the token read from POWER_TOKEN_FILE at print time still matches the
  # token Supervisor saw as SUPERVISOR_TOKEN at container boot.
  if [ -n "\${token}" ]; then
    log_msg "job=\${job_id} runtime token fingerprint: len=\${#token}:\${token:0:6}...\${token: -6}"
  fi
  # DIAGNOSTIC: pull the boot-time fingerprint from STARTUP_LOG_FILE (rather
  # than relying on it still being visible in the live/rotating container
  # log, which verbose cupsd debug output can push out) so both fingerprints
  # land together in the reliably-tailed power-wrapper log for direct diff.
  local boot_fp=""
  if [ -f "\${STARTUP_LOG_FILE}" ]; then
    boot_fp="\$(grep -o 'boot token fingerprint:.*' "\${STARTUP_LOG_FILE}" 2>/dev/null | tail -n1 || true)"
    log_msg "job=\${job_id} \${boot_fp:-boot token fingerprint: <not found in startup.log>}"
  fi
  # DIAGNOSTIC: read the CURRENT boot counter (a persistent /data file,
  # incremented by cont-init.d on every container start) at the moment of
  # this print job. If this number is HIGHER than the boot count recorded
  # in startup.log at the time this wrapper's token was captured, the
  # container has restarted AGAIN since then -- proving Supervisor has
  # already rotated to a newer token while this print job was in flight.
  if [ -f "\${BOOT_COUNT_FILE}" ]; then
    current_boot_count="\$(grep -o '^BOOT_COUNT=.*' "\${BOOT_COUNT_FILE}" 2>/dev/null || true)"
    startup_boot_count="\$(grep -o 'boot count=[0-9]*' "\${STARTUP_LOG_FILE}" 2>/dev/null | tail -n1 || true)"
    log_msg "job=\${job_id} current \${current_boot_count:-<unknown>} vs at-startup \${startup_boot_count:-<unknown>}"
  fi

  if [ -z "\${entity_id}" ] || [ -z "\${token}" ]; then
    log_msg "job=\${job_id} skip power_on_switch due to missing entity_id or supervisor token"
    return 0
  fi

  # DIAGNOSTIC: call an endpoint that goes through Supervisor's FULL
  # token_validation middleware (same from_token()+access_homeassistant_api
  # check as switch.turn_on's _check_access(), just via a different code
  # path) at the exact same moment, with the exact same token, right before
  # the actual switch.turn_on call. If this ALSO returns 401 here, the token
  # itself is genuinely invalid/revoked at print time (not just a boot vs.
  # print-time file mismatch, which we already ruled out). If this succeeds
  # while switch.turn_on still fails, the problem is specific to that
  # endpoint/request, not the token or permissions.
  # DIAGNOSTIC: also capture the response BODY (truncated), not just the
  # status code, in the SAME curl call (a trailing "HTTP_CODE:NNN" marker is
  # appended to the body via -w and split back out below) so this stays a
  # single same-moment request rather than two separate ones. Supervisor's
  # rejection responses carry a "message" field (e.g. "Invalid password" /
  # "Unknown Home Assistant API access!" / "Not permitted API access") that
  # tells us EXACTLY which check failed -- a status code alone leaves
  # multiple possible causes ambiguous.
  local self_check_raw self_check_body self_check_code
  self_check_raw=$(curl -sS --max-time 10 -w "HTTP_CODE:%{http_code}" \
    -H "Authorization: Bearer \${token}" \
    "http://supervisor/addons/self/info" 2>&1 || echo "curl_failed")
  self_check_code="\${self_check_raw##*HTTP_CODE:}"
  self_check_body="\${self_check_raw%HTTP_CODE:*}"
  log_msg "job=\${job_id} same-moment self-check result=http_\${self_check_code} body=\${self_check_body:0:200}"

  local http_raw http_body http_code
  http_raw=$(curl -sS --max-time 10 -w "HTTP_CODE:%{http_code}" -X POST \
    -H "Authorization: Bearer \${token}" \
    -H "Content-Type: application/json" \
    -d "{\"entity_id\":\"\${entity_id}\"}" \
    "http://supervisor/core/api/services/switch/turn_on" 2>&1 || echo "curl_failed")
  http_code="\${http_raw##*HTTP_CODE:}"
  http_body="\${http_raw%HTTP_CODE:*}"
  log_msg "job=\${job_id} switch.turn_on result=http_\${http_code} body=\${http_body:0:200}"

  if [[ "\${delay}" =~ ^[0-9]+$ ]] && [ "\${delay}" -gt 0 ]; then
    log_msg "job=\${job_id} sleeping \${delay}s before forwarding job"
    sleep "\${delay}"
  fi
}

# Backends are called without job arguments for discovery.
if [ "\$#" -ge 5 ]; then
  log_msg "backend_call mode=job args=\$# job_id=\${1:-unknown} user=\${2:-unknown} title=\${3:-unknown} copies=\${4:-unknown}"
  power_on_switch "\${1:-unknown}"
else
  log_msg "backend_call mode=discovery args=\$#"
fi

log_msg "exec backend_real=\${BACKEND_REAL}"
exec "\${BACKEND_REAL}" "\$@"
EOF

  chmod 755 "${target}"
  return 0
}

restore_backend() {
  local backend="$1"
  local target="${BACKEND_DIR}/${backend}"
  local real="${BACKEND_DIR}/${backend}.real"

  if [ -e "${real}" ]; then
    rm -f "${target}"
    mv "${real}" "${target}"
  fi
}

detect_backend_dir() {
  if [ -d /usr/lib/cups/backend ]; then
    BACKEND_DIR="/usr/lib/cups/backend"
  elif [ -d /usr/libexec/cups/backend ]; then
    BACKEND_DIR="/usr/libexec/cups/backend"
  else
    BACKEND_DIR=""
  fi
}

append_backend_schemes_from_queues() {
  local queue_file="/data/cups/config/printers.conf"
  local schemes

  if [ ! -f "${queue_file}" ]; then
    return 0
  fi

  schemes=$(sed -n 's/^[[:space:]]*DeviceURI[[:space:]]\+\([a-zA-Z0-9+.-]\+\):.*/\1/p' "${queue_file}" | tr 'A-Z' 'a-z' | sort -u)
  if [ -n "${schemes}" ]; then
    POWER_WRAPPED_BACKENDS="${POWER_WRAPPED_BACKENDS} ${schemes}"
  fi
}

power_on_switch_api() {
  local source="$1"
  local token="${SUPERVISOR_TOKEN:-}"
  local http_code

  if [ -z "${POWER_SWITCH_ENTITY_ID}" ] || [ -z "${token}" ]; then
    log_startup "${source}: skip switch.turn_on (missing entity_id or supervisor token)"
    return 0
  fi

  http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"entity_id\":\"${POWER_SWITCH_ENTITY_ID}\"}" \
    "http://supervisor/core/api/services/switch/turn_on" || echo "curl_failed")

  log_startup "${source}: switch.turn_on result=http_${http_code} entity=${POWER_SWITCH_ENTITY_ID}"

  if [[ "${POWER_ON_DELAY}" =~ ^[0-9]+$ ]] && [ "${POWER_ON_DELAY}" -gt 0 ]; then
    log_startup "${source}: waiting ${POWER_ON_DELAY}s before continuing"
    sleep "${POWER_ON_DELAY}"
  fi
}

start_job_monitor() {
  if [ "${POWER_ON_BEFORE_PRINT}" != "true" ] || [ -z "${POWER_SWITCH_ENTITY_ID}" ]; then
    return 0
  fi

  (
    last_spool_sig=""
    tick=0
    log_startup "job-monitor: loop active"

    while true; do
      spool_sig=$(ls -1 /var/spool/cups/d* 2>/dev/null | xargs -I{} basename {} 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')

      if [ -n "${spool_sig}" ] && [ "${spool_sig}" != "${last_spool_sig}" ]; then
        log_startup "job-monitor: detected spool activity files=${spool_sig}"
        power_on_switch_api "job-monitor-spool"
        last_spool_sig="${spool_sig}"
      fi

      if [ -z "${spool_sig}" ]; then
        last_spool_sig=""
      fi

      tick=$((tick + 1))
      if [ $((tick % 10)) -eq 0 ]; then
        cupsd_alive="no"
        if pgrep -x cupsd >/dev/null 2>&1; then
          cupsd_alive="yes"
        fi
        port_status="closed"
        if (echo >/dev/tcp/127.0.0.1/631) >/dev/null 2>&1; then
          port_status="open"
        fi
        log_startup "job-monitor: heartbeat spool=${spool_sig:-<none>} cupsd_alive=${cupsd_alive} port631=${port_status}"
      fi

      sleep 2
    done
  ) &

  log_startup "job-monitor: started fallback watcher pid=$!"
}

ensure_admin_permissions() {
  local cupsd_conf="/data/cups/config/cupsd.conf"

  if [ ! -f "${cupsd_conf}" ]; then
    return 0
  fi

  if grep -q "HA_CUPS_ADMIN_RIGHTS" "${cupsd_conf}"; then
    return 0
  fi

  cat >> "${cupsd_conf}" << 'EOL'

# HA_CUPS_ADMIN_RIGHTS
# Historically this appended IPP-operation <Limit> blocks (Cancel-Job,
# CUPS-Add-Modify-Printer, etc.) here at/near the top level. That was
# invalid on two counts: (1) <Limit> must be nested inside <Location> or
# <Policy>, never standalone, and (2) IPP operation names are only valid
# inside a <Policy>'s <Limit> - inside a <Location>'s <Limit> the
# arguments must be HTTP methods (GET/POST/etc), so wrapping them in
# <Location /> (tried previously) still produced "Unknown request type"
# warnings, plus a "Duplicate <Location />" warning since the base
# template already defines one. Since the base template's <Location />
# already grants full LAN access to every request regardless of
# operation, these blocks never added any actual restriction even when
# "working" - removed as redundant rather than reimplemented via
# <Policy>, to avoid the risk of an incorrectly-scoped policy
# accidentally denying operations that currently work fine.
EOL
}

ensure_debug_logging() {
  local cupsd_conf="/data/cups/config/cupsd.conf"

  if [ ! -f "${cupsd_conf}" ]; then
    return 0
  fi

  # Normalize LogLevel to "warn" every boot, regardless of history. Earlier
  # iterations of this add-on (including the initial cupsd.conf template
  # below) enabled "LogLevel debug" to diagnose backend/connection setup
  # issues. That is now confirmed working, and debug-level cupsd output
  # (CGI/PPD dumps, etc.) floods the small rolling log window that HA's log
  # viewer/download captures, pushing out the power-hook diagnostics we
  # actually need. "warn" still surfaces real errors without the noise. Use
  # sed so this also corrects already-provisioned cupsd.conf files on
  # existing installs, not just fresh ones.
  if grep -q "^LogLevel " "${cupsd_conf}"; then
    if grep -q "^LogLevel debug" "${cupsd_conf}"; then
      # One-time cleanup: MaxLogSize 0 means cupsd NEVER rotates/truncates
      # error_log on its own, so months of old "debug" output sit in the
      # persisted log file forever, permanently eating the rolling log
      # window even after switching to "warn". Truncate the accumulated
      # debug backlog exactly once, at the moment we detect the old
      # "debug" setting, so it doesn't keep crowding out useful output.
      : > /data/cups/logs/error_log 2>/dev/null || true
      : > /data/cups/logs/access_log 2>/dev/null || true
      : > /data/cups/logs/page_log 2>/dev/null || true
      log_startup "cleared accumulated debug-level cupsd logs (one-time, migrating LogLevel debug -> warn)"
    fi
    sed -i.bak 's/^LogLevel .*/LogLevel warn/' "${cupsd_conf}"
    rm -f "${cupsd_conf}.bak"
  elif ! grep -q "HA_CUPS_DEBUG_LOGGING\|HA_CUPS_LOG_LEVEL" "${cupsd_conf}"; then
    cat >> "${cupsd_conf}" << 'EOL'

# HA_CUPS_LOG_LEVEL
LogLevel warn
MaxLogSize 0
EOL
  fi
}

write_default_cupsd_conf() {
  # Extracted into a function (rather than an inline heredoc guarded by
  # `if [ ! -f cupsd.conf ]`) so it can ALSO be invoked as a same-boot
  # self-heal regeneration below, when cupsd's own config test proves the
  # persisted file is corrupted beyond what the targeted single-line repairs
  # in ensure_log_paths can fix. Overwrites unconditionally - callers are
  # responsible for deciding whether regeneration is appropriate.
  #
  # IMPORTANT: the heredoc delimiter below is QUOTED ('EOL', not EOL). This
  # is required, not stylistic: an earlier unquoted version caused bash to
  # expand backticks/$ INSIDE the heredoc body, so the comment below
  # mentioning `cupsd -t` was literally executed as a command substitution
  # every time this function ran, splicing cupsd -t's own "is OK" output
  # into the generated file and corrupting it (root cause of the persistent
  # "Unknown directive" errors seen on every boot, made WORSE by the
  # self-heal regeneration since it re-ran this same broken generation).
  cat > /data/cups/config/cupsd.conf << 'EOL'
# Listen on all interfaces
Listen 0.0.0.0:631

# Use persistent storage as CUPS server root
ServerRoot /data/cups/config

# Reduced from "debug" once backend/connection setup was confirmed working;
# debug-level output was flooding the small rolling log window HA captures.
# See ensure_debug_logging, which also normalizes this on existing installs.
LogLevel warn
MaxLogSize 0

# NOTE: ErrorLog/AccessLog/PageLog are intentionally NOT set here. Modern
# CUPS (since 1.6) requires these in cups-files.conf, not cupsd.conf -
# cupsd -t reported them as unknown directives when placed here, which is
# why cupsd previously never wrote any log output. See ensure_cups_files_conf.

# Enable DNS-SD/mDNS browsing and shared queues
Browsing On
BrowseLocalProtocols dnssd
DefaultShared Yes

# Allow access from local network
<Location />
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

# Admin access (no authentication)
<Location /admin>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

# Job management permissions
<Location /jobs>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

# NOTE: an IPP-operation <Limit> block (Send-Document, Cancel-Job, etc.)
# used to be placed here. It never actually worked: <Limit> must be
# nested inside <Location>/<Policy> (a standalone one is an "Unknown
# directive"), and even nested inside <Location> the arguments must be
# HTTP methods, not IPP operation names (nesting IPP operation names in
# <Location> produces "Unknown request type" plus a "Duplicate <Location
# />" warning, since one is already defined above). Since <Location />
# above already grants full LAN access to every request/operation
# regardless, this never added any actual restriction - removed as
# redundant rather than reimplemented via <Policy>, to avoid the risk of
# an incorrectly-scoped policy denying operations that work fine today.

# Enable web interface
WebInterface Yes

# Default settings
DefaultAuthType None
PreserveJobHistory No
EOL
}

ensure_log_permissions() {
  # cupsd typically drops root privileges and runs its scheduler as user
  # "lp"/group "lp" (Alpine's compiled-in default; we never set User/Group
  # in cupsd.conf). Files we create here via touch/echo as root default to
  # root:root mode 644, which gives group "lp" read-only access - cupsd can
  # then never write a single line to its own log files, and silently
  # produces no output at all. Force group-writable ownership so cupsd can
  # actually write, and setgid the directory so any future rotated/recreated
  # log files inherit group "lp" automatically.
  mkdir -p /data/cups/logs
  chown root:lp /data/cups/logs
  chmod 2775 /data/cups/logs

  local f
  for f in error_log access_log page_log; do
    touch "/data/cups/logs/${f}"
    chown root:lp "/data/cups/logs/${f}"
    chmod 664 "/data/cups/logs/${f}"
  done
}

start_error_log_tail() {
  local log_file="/data/cups/logs/error_log"

  mkdir -p "$(dirname "${log_file}")"
  touch "${log_file}"

  # Self-test canary: written BEFORE the tail pipeline starts, then read back
  # via -n +1 (from the beginning) rather than -n 0. This lets us tell apart
  # "the tail pipeline itself is broken" (canary never appears) from "cupsd
  # just isn't writing to this file" (canary appears, but nothing from cupsd
  # ever follows).
  echo "$(date -Iseconds 2>/dev/null || date) HA_CUPS_LOG_TAIL_CANARY: if you see this line, the log-tail pipeline is working; absence of cupsd lines after it means cupsd itself is not writing to this file." >> "${log_file}"

  (
    # Use -f rather than -F: BusyBox's tail (the default on this Alpine base
    # image, since coreutils is not installed) has unreliable/absent support
    # for -F (retry-on-rotation). MaxLogSize 0 in cupsd.conf disables log
    # rotation, so the file is never recreated and plain -f is sufficient.
    tail -n +1 -f "${log_file}" 2>/dev/null | while IFS= read -r line; do
      echo "[cupsd-error-log] ${line}"
    done
  ) &

  log_startup "started error_log tail pid=$!"
}

start_power_wrapper_log_tail() {
  # The backend wrapper writes its own diagnostics to POWER_LOG_FILE (it also
  # best-effort writes directly to /proc/1/fd/1, but that write commonly
  # fails silently since backends run as user "lp", not root, and may not
  # have permission to write to PID 1's stdout fd). Tailing the file here is
  # the reliable path to surface wrapper activity (or the lack of it) in the
  # visible add-on log.
  mkdir -p "$(dirname "${POWER_LOG_FILE}")"
  touch "${POWER_LOG_FILE}"

  (
    tail -n +1 -f "${POWER_LOG_FILE}" 2>/dev/null | while IFS= read -r line; do
      echo "[power-wrapper-log] ${line}"
    done
  ) &

  log_startup "started power-wrapper log tail pid=$!"
}

ensure_log_paths() {
  local cupsd_conf="/data/cups/config/cupsd.conf"

  if [ ! -f "${cupsd_conf}" ]; then
    return 0
  fi

  # A previous iteration appended ErrorLog/AccessLog/PageLog directly into
  # cupsd.conf under the HA_CUPS_LOG_PATHS marker. `cupsd -t` confirmed these
  # are "Unknown directive" here on this CUPS version (they belong in
  # cups-files.conf since CUPS 1.6 - see ensure_cups_files_conf), so cupsd
  # silently ignored them and never produced any log output. Clean up that
  # stale, non-functional block so it stops being reported by `cupsd -t`.
  if grep -q "HA_CUPS_LOG_PATHS" "${cupsd_conf}"; then
    sed -i.bak '/# HA_CUPS_LOG_PATHS/,/^PageLog /d' "${cupsd_conf}"
    rm -f "${cupsd_conf}.bak"
  fi

  # JobSheets is also confirmed "Unknown directive" on this CUPS version;
  # remove any stray occurrence left over from an older template.
  if grep -q "^JobSheets" "${cupsd_conf}"; then
    sed -i.bak '/^JobSheets/d' "${cupsd_conf}"
    rm -f "${cupsd_conf}.bak"
  fi

  # Observed in the wild: cupsd erroring with
  # `Unknown directive "/etc/cups/cupsd.conf" on line N of
  # /data/cups/config/cupsd.conf.` - meaning the persisted config somehow
  # picked up a bare line containing just the /etc/cups/cupsd.conf symlink
  # path, which is not a valid directive/value pair. Origin unconfirmed
  # (possibly introduced by a much older version of this script, or by
  # manual editing), but since this file is created once and reused forever
  # (see the `if [ ! -f cupsd.conf ]` guard above), any such stray line
  # persists across every future add-on update unless explicitly repaired
  # here. Strip it defensively so cupsd can parse the file cleanly.
  if grep -qx '[[:space:]]*/etc/cups/cupsd\.conf[[:space:]]*' "${cupsd_conf}"; then
    sed -i.bak '/^[[:space:]]*\/etc\/cups\/cupsd\.conf[[:space:]]*$/d' "${cupsd_conf}"
    rm -f "${cupsd_conf}.bak"
    log_startup "removed stray '/etc/cups/cupsd.conf' line from cupsd.conf (invalid directive, cause unconfirmed)"
  fi

  # DIAGNOSTIC: dump the persisted cupsd.conf (numbered, so it can be
  # directly cross-referenced against any future "Unknown directive on
  # line N" error) to startup.log. This file has repeatedly drifted from
  # what the current script expects (stale LogLevel, stale HA_CUPS_LOG_PATHS
  # block, stray JobSheets/path lines above) because it is created once and
  # never regenerated - direct visibility into its actual persisted content
  # is far more reliable than continuing to guess at its structure.
  log_startup "cupsd.conf content follows:"
  while IFS= read -r conf_line; do
    log_startup "cupsd.conf: ${conf_line}"
  done < <(nl -ba "${cupsd_conf}")
}

ensure_cups_files_conf() {
  local cups_files_conf="/data/cups/config/cups-files.conf"

  if [ -f "${cups_files_conf}" ] && grep -q "HA_CUPS_FILES_CONF" "${cups_files_conf}"; then
    return 0
  fi

  # ErrorLog/AccessLog/PageLog (and User/Group) belong in cups-files.conf on
  # modern CUPS, NOT cupsd.conf - confirmed via `cupsd -t`, which flagged
  # them as unknown directives when placed in cupsd.conf. Without this file,
  # cupsd silently used compiled-in defaults instead of our persisted paths.
  cat > "${cups_files_conf}" << 'EOL'
# HA_CUPS_FILES_CONF
ErrorLog /data/cups/logs/error_log
AccessLog /data/cups/logs/access_log
PageLog /data/cups/logs/page_log
User lp
Group lp
EOL

  chown root:lp "${cups_files_conf}"
  chmod 664 "${cups_files_conf}"
}

# Create CUPS data directories for persistence
mkdir -p /data/cups/cache
mkdir -p /data/cups/logs
mkdir -p /data/cups/state
mkdir -p /data/cups/config
mkdir -p /data/cups/config/ppd
mkdir -p /data/cups/config/ssl

# Set proper permissions
chown -R root:lp /data/cups
chmod -R 775 /data/cups
touch "${POWER_LOG_FILE}"
chown root:lp "${POWER_LOG_FILE}"
chmod 664 "${POWER_LOG_FILE}"

# DIAGNOSTIC: persistent boot counter + timestamp, survives container restarts
# (stored in /data, not tied to this specific container instance). Every
# cont-init.d run is a container (re)start, and each restart mints Supervisor
# a brand new SUPERVISOR_TOKEN (see supervisor/apps/app.py App.start()).
# If this count increments far more often than expected (e.g. every few
# minutes with no user-initiated restart), the add-on container is
# unexpectedly restarting/crash-looping, which would explain intermittent
# switch.turn_on 401s: a stale in-flight token can straddle a restart
# boundary and be rejected by the time the actual request reaches Supervisor.
BOOT_COUNT_FILE="/data/cups/config/.boot_count"
prev_boot_count=0
prev_boot_epoch=0
if [ -f "${BOOT_COUNT_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${BOOT_COUNT_FILE}"
  prev_boot_count="${BOOT_COUNT:-0}"
  prev_boot_epoch="${BOOT_EPOCH:-0}"
fi
new_boot_count=$((prev_boot_count + 1))
new_boot_epoch=$(date +%s)
seconds_since_prev="unknown"
if [ "${prev_boot_epoch}" -gt 0 ] 2>/dev/null; then
  seconds_since_prev=$((new_boot_epoch - prev_boot_epoch))
fi
{
  echo "BOOT_COUNT=${new_boot_count}"
  echo "BOOT_EPOCH=${new_boot_epoch}"
} > "${BOOT_COUNT_FILE}"
log_startup "boot count=${new_boot_count} seconds_since_previous_boot=${seconds_since_prev}"

POWER_ON_BEFORE_PRINT="false"
POWER_SWITCH_ENTITY_ID=""
POWER_ON_DELAY="0"

if declare -F bashio::config >/dev/null 2>&1; then
  log_startup "loading options via bashio"
  POWER_ON_BEFORE_PRINT="$(bashio::config 'power_on_before_print')"
  POWER_SWITCH_ENTITY_ID="$(bashio::config 'power_switch_entity_id')"
  POWER_ON_DELAY="$(bashio::config 'power_on_delay')"
else
  log_startup "bashio not found, loading options via /data/options.json"
  POWER_ON_BEFORE_PRINT="$(read_option_bool 'power_on_before_print' 'false')"
  POWER_SWITCH_ENTITY_ID="$(read_option_str 'power_switch_entity_id' '')"
  POWER_ON_DELAY="$(read_option_int 'power_on_delay' '0')"
fi

log_startup "resolved config: enabled=${POWER_ON_BEFORE_PRINT} entity=${POWER_SWITCH_ENTITY_ID:-<empty>} delay=${POWER_ON_DELAY}s"

detect_backend_dir
if [ -z "${BACKEND_DIR}" ]; then
  log_startup "no CUPS backend directory found; skipping wrapper installation"
fi
append_backend_schemes_from_queues
log_startup "effective backend candidates: $(printf '%s\n' ${POWER_WRAPPED_BACKENDS} | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ')"

if [ "${POWER_ON_BEFORE_PRINT}" = "true" ] && [ -n "${POWER_SWITCH_ENTITY_ID}" ] && [ -n "${BACKEND_DIR}" ]; then
  # NOTE: exporting these as env vars does NOT work - cupsd runs backends
  # with a security-sanitized environment and strips custom variables
  # before exec'ing them (confirmed: even SUPERVISOR_TOKEN, a genuine
  # container-level env var, never reached the wrapper). Persist them to
  # files instead; the wrapper reads these directly at invocation time.
  cat > "${POWER_STATE_FILE}" << EOF
HA_POWER_SWITCH_ENTITY_ID="${POWER_SWITCH_ENTITY_ID}"
HA_POWER_ON_DELAY="${POWER_ON_DELAY}"
EOF
  chown root:lp "${POWER_STATE_FILE}"
  chmod 640 "${POWER_STATE_FILE}"

  printf '%s' "${SUPERVISOR_TOKEN:-}" > "${POWER_TOKEN_FILE}"
  chown root:lp "${POWER_TOKEN_FILE}"
  chmod 640 "${POWER_TOKEN_FILE}"

  log_startup "enabled: entity=${POWER_SWITCH_ENTITY_ID} delay=${POWER_ON_DELAY}s backend_dir=${BACKEND_DIR} token_present=$([ -n "${SUPERVISOR_TOKEN:-}" ] && echo yes || echo no)"

  # DIAGNOSTIC: ask Supervisor (self API, gated by hassio_api: true, which is
  # already granted) whether IT currently believes this add-on has
  # homeassistant_api access. This is checked live against Supervisor's
  # persisted app data on every proxy request, so it tells us definitively
  # whether a stale/un-synced permission (rather than a code bug) is the
  # cause of any 401 from the core/api proxy.
  if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    self_info="$(curl -sS --max-time 10 -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" http://supervisor/addons/self/info 2>&1 || true)"
    log_startup "supervisor self-check: $(printf '%s' "${self_info}" | grep -o '"homeassistant_api"[^,}]*\|"hassio_api"[^,}]*\|"version"[^,}]*' | tr '\n' ' ')"
    # DIAGNOSTIC: non-secret-leaking fingerprint (length + partial chars) of
    # the token as seen at boot time, to compare against the fingerprint
    # logged by the wrapper at actual print-job time (same value read from
    # POWER_TOKEN_FILE later). If these ever differ, the token itself (not
    # the homeassistant_api permission) is the cause of any 401.
    log_startup "boot token fingerprint: len=${#SUPERVISOR_TOKEN}:${SUPERVISOR_TOKEN:0:6}...${SUPERVISOR_TOKEN: -6}"
  fi

  for backend in $(printf '%s\n' ${POWER_WRAPPED_BACKENDS} | tr ' ' '\n' | awk 'NF' | sort -u); do
    install_power_wrapper "${backend}"
    case "$?" in
      0)
        log_startup "wrapper installed for backend=${backend}"
        ;;
      2)
        log_startup "wrapper skipped for backend=${backend} (backend not present)"
        ;;
      *)
        log_startup "wrapper install failed for backend=${backend}"
        ;;
    esac
  done
else
  log_startup "disabled: power_on_before_print=${POWER_ON_BEFORE_PRINT} entity=${POWER_SWITCH_ENTITY_ID:-<empty>}"
  rm -f "${POWER_STATE_FILE}" "${POWER_TOKEN_FILE}"
  if [ -n "${BACKEND_DIR}" ]; then
    for backend in $(printf '%s\n' ${POWER_WRAPPED_BACKENDS} | tr ' ' '\n' | awk 'NF' | sort -u); do
      restore_backend "${backend}"
      log_startup "wrapper restored for backend=${backend}"
    done
  fi
fi

# Create CUPS configuration directory if it doesn't exist
mkdir -p /etc/cups

# Persist queue metadata files that CUPS updates when printers are added or edited
touch /data/cups/config/printers.conf
touch /data/cups/config/classes.conf
touch /data/cups/config/subscriptions.conf
touch /data/cups/config/lpoptions
touch /data/cups/config/printers.conf.O
touch /data/cups/config/classes.conf.O
touch /data/cups/config/subscriptions.conf.O

# Ensure CUPS can write all persisted files
chown -R root:lp /data/cups/config
chmod -R ug+rwX /data/cups/config

# Create the server config once, then keep reusing the persistent copy
if [ ! -f /data/cups/config/cupsd.conf ]; then
  write_default_cupsd_conf
fi

ensure_admin_permissions
ensure_debug_logging
ensure_log_paths
ensure_cups_files_conf
ensure_log_permissions
start_error_log_tail
start_power_wrapper_log_tail

# Create a symlink from the default config location to our persistent location
ln -sf /data/cups/config/cupsd.conf /etc/cups/cupsd.conf
ln -sf /data/cups/config/cups-files.conf /etc/cups/cups-files.conf
ln -sf /data/cups/config/printers.conf /etc/cups/printers.conf
ln -sf /data/cups/config/printers.conf.O /etc/cups/printers.conf.O
ln -sf /data/cups/config/classes.conf /etc/cups/classes.conf
ln -sf /data/cups/config/classes.conf.O /etc/cups/classes.conf.O
ln -sf /data/cups/config/subscriptions.conf /etc/cups/subscriptions.conf
ln -sf /data/cups/config/subscriptions.conf.O /etc/cups/subscriptions.conf.O
ln -sf /data/cups/config/lpoptions /etc/cups/lpoptions
ln -sf /data/cups/config/ppd /etc/cups/ppd
ln -sf /data/cups/config/ssl /etc/cups/ssl

# Config self-test. If cupsd rejects/ignores a directive (e.g. one that
# doesn't belong in cupsd.conf on this CUPS version), it typically does so
# silently once started via -f, producing NO error_log output at all. This
# runs cupsd's own built-in config validator and captures its exact
# stdout/stderr, which is the authoritative source instead of guessing.
log_startup "cupsd config test starting"
cupsd_test_output="$(/usr/sbin/cupsd -t -c /data/cups/config/cupsd.conf 2>&1)"
cupsd_test_status=$?
if [ -n "${cupsd_test_output}" ]; then
  while IFS= read -r line; do
    log_startup "cupsd -t: ${line}"
  done <<< "${cupsd_test_output}"
else
  log_startup "cupsd -t: (no output)"
fi
log_startup "cupsd config test exit_code=${cupsd_test_status}"

# Self-heal: this persisted cupsd.conf is created ONCE (see the `if [ ! -f
# ]` guard above) and reused forever, accumulating patches from every add-on
# version it has lived through (LogLevel migrations, HA_CUPS_ADMIN_RIGHTS/
# HA_CUPS_LOG_PATHS marker blocks added and removed, etc). On some installs
# this has drifted into a state with multiple genuinely unparseable lines
# ("Unknown directive" at several different line numbers, discovered one at
# a time as each was individually patched) - patching single known-bad lines
# is whack-a-mole and cannot converge. If the config test reports errors,
# discard the file entirely and regenerate it fresh from the current
# template instead. This does NOT touch printers.conf/classes.conf/etc (a
# separate file), so configured printers are preserved.
if [ "${cupsd_test_status}" -ne 0 ] || printf '%s' "${cupsd_test_output}" | grep -qi "unknown directive"; then
  broken_backup="/data/cups/config/cupsd.conf.broken.$(date +%s 2>/dev/null || echo unknown)"
  log_startup "cupsd config test failed - regenerating cupsd.conf from template (backup: ${broken_backup})"
  cp /data/cups/config/cupsd.conf "${broken_backup}" 2>/dev/null || true
  write_default_cupsd_conf
  ensure_admin_permissions
  ensure_debug_logging
  ensure_log_paths

  cupsd_retest_output="$(/usr/sbin/cupsd -t -c /data/cups/config/cupsd.conf 2>&1)"
  cupsd_retest_status=$?
  if [ -n "${cupsd_retest_output}" ]; then
    while IFS= read -r line; do
      log_startup "cupsd -t (post-regen): ${line}"
    done <<< "${cupsd_retest_output}"
  else
    log_startup "cupsd -t (post-regen): (no output)"
  fi
  log_startup "cupsd config re-test exit_code=${cupsd_retest_status}"
fi

# Start DBus and Avahi for mDNS/Bonjour discovery
mkdir -p /run/dbus
if [ ! -f /run/dbus/pid ]; then
  dbus-daemon --system --fork
fi

mkdir -p /run/avahi-daemon
avahi-daemon --daemonize --no-chroot

# cupsd itself is started by /etc/services.d/cups/run so that it is properly
# supervised by s6-overlay (auto-restarted if it dies). cont-init.d scripts
# must exit for s6 to consider this init stage complete and proceed to start
# services.d; blocking here with `wait` on cupsd previously caused the whole
# init stage (and its child processes, including cupsd and the job monitor)
# to be torn down once s6 gave up waiting for this script to finish.
start_job_monitor
