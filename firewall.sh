#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="/opt/mail/compose.yml"

# 1. Get the IP address of the "mail" container from /opt/mail/compose.yml
MAIL_IP=$(docker compose -f "$COMPOSE_FILE" exec -T mail hostname -I 2>/dev/null | awk '{print $1}' || true)

if [ -z "$MAIL_IP" ]; then
    MAIL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(docker compose -f "$COMPOSE_FILE" ps -q mail 2>/dev/null) 2>/dev/null || true)
fi

if [ -z "$MAIL_IP" ]; then
    echo "Error: Could not retrieve IP for mail container from $COMPOSE_FILE." >&2
    exit 1
fi

# 2. Get the specific interface (eth|en) that holds a global/public IPv4 address, along with its IP
read -r PUBLIC_IFACE HOST_PUBLIC_IP < <(ip -4 -o addr show scope global | awk '{print $2, $4}' | cut -d'/' -f1 | grep -E '^(eth|en)' | head -n 1)

if [ -z "$PUBLIC_IFACE" ] || [ -z "$HOST_PUBLIC_IP" ]; then
    echo "Error: Could not determine public network interface or public IP starting with eth/en." >&2
    exit 1
fi

echo "Mail Container IP: ${MAIL_IP}"
echo "Public Interface:  ${PUBLIC_IFACE}"
echo "Host Public IP:    ${HOST_PUBLIC_IP}"

# 3. Flush/clean previous instances of our rules to avoid duplicates
iptables -D DOCKER-USER -p tcp -m multiport --dports 25,465,587 -s "${MAIL_IP}" -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -p tcp -m multiport --dports 25,465,587 -d "${MAIL_IP}" -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -p tcp -m multiport --dports 25,465,587 -d "${HOST_PUBLIC_IP}" -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -o "${PUBLIC_IFACE}" -p tcp -m multiport --dports 25,465,587 -j DROP 2>/dev/null || true

iptables -D OUTPUT -p tcp -m multiport --dports 25,465,587 -d "${MAIL_IP}" -j ACCEPT 2>/dev/null || true
iptables -D OUTPUT -p tcp -m multiport --dports 25,465,587 -d "${HOST_PUBLIC_IP}" -j ACCEPT 2>/dev/null || true
iptables -D OUTPUT -o "${PUBLIC_IFACE}" -p tcp -m multiport --dports 25,465,587 -j DROP 2>/dev/null || true

# 4. Insert dynamic rules

# DOCKER-USER Chain (Container Traffic)
# 1. Allow the mail container itself to send outbound SMTP traffic to external hosts
iptables -I DOCKER-USER 1 -p tcp -m multiport --dports 25,465,587 -s "${MAIL_IP}" -j ACCEPT
# 2. Allow other containers to reach the mail container IP directly
iptables -I DOCKER-USER 2 -p tcp -m multiport --dports 25,465,587 -d "${MAIL_IP}" -j ACCEPT
# 3. Allow other containers to reach the host's public IP (for published mail ports)
iptables -I DOCKER-USER 3 -p tcp -m multiport --dports 25,465,587 -d "${HOST_PUBLIC_IP}" -j ACCEPT
# 4. Drop all other container outbound SMTP traffic departing via the public interface
iptables -A DOCKER-USER -o "${PUBLIC_IFACE}" -p tcp -m multiport --dports 25,465,587 -j DROP

# OUTPUT Chain (Host-initiated Traffic)
# 1. Allow host processes to reach the mail container directly
iptables -I OUTPUT 1 -p tcp -m multiport --dports 25,465,587 -d "${MAIL_IP}" -j ACCEPT
# 2. Allow host processes to reach the host public IP
iptables -I OUTPUT 2 -p tcp -m multiport --dports 25,465,587 -d "${HOST_PUBLIC_IP}" -j ACCEPT
# 3. Block host processes from reaching external third-party mail servers directly
iptables -A OUTPUT -o "${PUBLIC_IFACE}" -p tcp -m multiport --dports 25,465,587 -j DROP

echo "Firewall rules updated successfully."

