#!/usr/bin/env bash
# Opens the Omada Controller ports on the active firewalld zone.
# Required because the container uses host networking: all traffic is filtered
# by the host firewall (Fedora Server default zone only allows ssh/cockpit/dhcpv6).
#
# Run as root on the fedora host:  sudo bash open-firewall.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo bash $0)" >&2
  exit 1
fi

ZONE="${OMADA_ZONE:-$(firewall-cmd --get-default-zone)}"
echo "INFO: opening Omada ports on firewalld zone '${ZONE}'"

# web UI: management HTTP/HTTPS, captive portal HTTPS, ES-series upgrade HTTPS
for p in 8088/tcp 8043/tcp 8843/tcp 8044/tcp; do
  firewall-cmd --permanent --zone="${ZONE}" --add-port="${p}"
done

# discovery (controller <-> devices, Omada app) and device management range
firewall-cmd --permanent --zone="${ZONE}" --add-port=27001/udp
firewall-cmd --permanent --zone="${ZONE}" --add-port=29810/udp
firewall-cmd --permanent --zone="${ZONE}" --add-port=19810/udp
firewall-cmd --permanent --zone="${ZONE}" --add-port=29811-29817/tcp

firewall-cmd --reload
echo "INFO: done; current ports on zone '${ZONE}':"
firewall-cmd --zone="${ZONE}" --list-ports
