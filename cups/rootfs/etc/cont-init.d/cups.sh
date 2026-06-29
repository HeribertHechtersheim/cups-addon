#!/usr/bin/with-contenv bash

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

<Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
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