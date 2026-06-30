#!/usr/bin/with-contenv bash

if [ -f /usr/lib/bashio/bashio.sh ]; then
  # shellcheck source=/dev/null
  source /usr/lib/bashio/bashio.sh
fi

BACKEND_DIR="/usr/lib/cups/backend"
POWER_WRAPPED_BACKENDS="socket ipp ipps lpd usb dnssd"
POWER_LOG_FILE="/data/cups/logs/power-wrapper.log"

log_startup() {
  local message="$1"
  echo "[power-hook] ${message}"
  echo "[power-hook] ${message}" >> "${POWER_LOG_FILE}" 2>/dev/null || true
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
    return 0
  fi

  if [ -e "${target}" ] && [ ! -e "${real}" ]; then
    mv "${target}" "${real}"
  fi

  cat > "${target}" << EOF
#!/usr/bin/env bash
set -euo pipefail

BACKEND_REAL="${real}"
POWER_LOG_FILE="${POWER_LOG_FILE}"

log_msg() {
  local message="\${1:-}"
  local now
  now="\$(date -Iseconds 2>/dev/null || date)"
  mkdir -p "\$(dirname "\${POWER_LOG_FILE}")" >/dev/null 2>&1 || true
  echo "\${now} [power-hook-wrapper] \${message}" >> "\${POWER_LOG_FILE}" 2>/dev/null || true
  if [ -w /proc/1/fd/1 ]; then
    echo "\${now} [power-hook-wrapper] \${message}" > /proc/1/fd/1 2>/dev/null || true
  fi
}

power_on_switch() {
  local entity_id="\${HA_POWER_SWITCH_ENTITY_ID:-}"
  local delay="\${HA_POWER_ON_DELAY:-0}"
  local token="\${SUPERVISOR_TOKEN:-}"
  local job_id="\${1:-unknown}"

  log_msg "job=\${job_id} power_on_switch invoked entity=\${entity_id:-<empty>} delay=\${delay} token_present=\$([ -n "\${token}" ] && echo yes || echo no)"

  if [ -z "\${entity_id}" ] || [ -z "\${token}" ]; then
    log_msg "job=\${job_id} skip power_on_switch due to missing entity_id or supervisor token"
    return 0
  fi

  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
    -H "Authorization: Bearer \${token}" \
    -H "Content-Type: application/json" \
    -d "{\"entity_id\":\"\${entity_id}\"}" \
    "http://supervisor/core/api/services/switch/turn_on" || echo "curl_failed")

  log_msg "job=\${job_id} switch.turn_on result=http_\${http_code}"

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
# Allow LAN users to manage and cancel jobs from the web UI.
<Limit Cancel-Job Cancel-My-Jobs Cancel-Current-Job Purge-Jobs CUPS-Move-Job>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Limit>

<Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Accept-Jobs CUPS-Reject-Jobs Pause-Printer Resume-Printer Enable-Printer Disable-Printer>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Limit>
EOL
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

if [ "${POWER_ON_BEFORE_PRINT}" = "true" ] && [ -n "${POWER_SWITCH_ENTITY_ID}" ]; then
  export HA_POWER_SWITCH_ENTITY_ID="${POWER_SWITCH_ENTITY_ID}"
  export HA_POWER_ON_DELAY="${POWER_ON_DELAY}"

  log_startup "enabled: entity=${POWER_SWITCH_ENTITY_ID} delay=${POWER_ON_DELAY}s"

  for backend in ${POWER_WRAPPED_BACKENDS}; do
    install_power_wrapper "${backend}"
    log_startup "wrapper installed for backend=${backend}"
  done
else
  log_startup "disabled: power_on_before_print=${POWER_ON_BEFORE_PRINT} entity=${POWER_SWITCH_ENTITY_ID:-<empty>}"
  for backend in ${POWER_WRAPPED_BACKENDS}; do
    restore_backend "${backend}"
    log_startup "wrapper restored for backend=${backend}"
  done
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
  cat > /data/cups/config/cupsd.conf << EOL
# Listen on all interfaces
Listen 0.0.0.0:631

# Use persistent storage as CUPS server root
ServerRoot /data/cups/config

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

<Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Limit>

# Enable web interface
WebInterface Yes

# Default settings
DefaultAuthType None
JobSheets none,none
PreserveJobHistory No
EOL
fi

ensure_admin_permissions

# Create a symlink from the default config location to our persistent location
ln -sf /data/cups/config/cupsd.conf /etc/cups/cupsd.conf
ln -sf /data/cups/config/printers.conf /etc/cups/printers.conf
ln -sf /data/cups/config/printers.conf.O /etc/cups/printers.conf.O
ln -sf /data/cups/config/classes.conf /etc/cups/classes.conf
ln -sf /data/cups/config/classes.conf.O /etc/cups/classes.conf.O
ln -sf /data/cups/config/subscriptions.conf /etc/cups/subscriptions.conf
ln -sf /data/cups/config/subscriptions.conf.O /etc/cups/subscriptions.conf.O
ln -sf /data/cups/config/lpoptions /etc/cups/lpoptions
ln -sf /data/cups/config/ppd /etc/cups/ppd
ln -sf /data/cups/config/ssl /etc/cups/ssl

# Start DBus and Avahi for mDNS/Bonjour discovery
mkdir -p /run/dbus
if [ ! -f /run/dbus/pid ]; then
  dbus-daemon --system --fork
fi

mkdir -p /run/avahi-daemon
avahi-daemon --daemonize --no-chroot

# Start CUPS service
/usr/sbin/cupsd -f -c /data/cups/config/cupsd.conf