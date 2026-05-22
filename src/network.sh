#!/usr/bin/env bash
set -Eeuo pipefail

# ######################################
#  Secondary Network Configuration
#  RadminVPN / eth1 / QEMU integration
# ######################################

: "${NETWORK:="Y"}"
: "${ADAPTER:="virtio-net-pci"}"
: "${HOST:=""}"
: "${STORAGE:="/storage"}"
: "${PROCESS:="qemu"}"
: "${DEBUG:=""}"
: "${MTU:="0"}"
: "${ADD_ERR:="Please add the following setting to your container:"}"

: "${SECONDARY_MAC:=""}"
: "${SECONDARY_IFACE:="eth1"}"
: "${SECONDARY_TAP:="tap1"}"
: "${SECONDARY_BRIDGE:="br1"}"
: "${SECONDARY_ADAPTER:="${ADAPTER}"}"

# ######################################
#  Initialize Secondary Network
# ######################################

if [[ "$NETWORK" == [Nn]* ]]; then
  [[ "$DEBUG" == [Yy1]* ]] && echo "Primary network disabled, skipping secondary RadminVPN network."
  return 0
fi

if [ -d "/sys/class/net/$SECONDARY_IFACE" ]; then

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring secondary network ($SECONDARY_IFACE) for QEMU..."

  # Generate or restore a persistent deterministic MAC for the secondary NIC
  if [ -z "$SECONDARY_MAC" ]; then
    local file="$STORAGE/$PROCESS.mac2"
    [ -s "$file" ] && SECONDARY_MAC=$(<"$file")
    SECONDARY_MAC="${SECONDARY_MAC//[![:print:]]/}"
    if [ -z "$SECONDARY_MAC" ]; then
      SECONDARY_MAC=$(echo "${HOST}-${SECONDARY_IFACE}" | md5sum | \
        sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
      echo "${SECONDARY_MAC^^}" > "$file"
    fi
  fi

  SECONDARY_MAC="${SECONDARY_MAC^^}"

  # Collect original IP and gateway from eth1
  ETH1_CIDR=$(ip -4 addr show "$SECONDARY_IFACE" | awk '/inet / {print $2}' | head -n1 || true)
  ETH1_GW=$(ip route | awk "/default.*$SECONDARY_IFACE/ {print \$3}" | head -n1 || true)

  # Detect MTU from secondary interface
  if [ -f "/sys/class/net/$SECONDARY_IFACE/mtu" ]; then
    SECONDARY_MTU=$(< "/sys/class/net/$SECONDARY_IFACE/mtu")
  else
    SECONDARY_MTU="$MTU"
  fi

  # Remove lingering tap/bridge from a previous run
  ip link set "$SECONDARY_TAP" down &>/dev/null || true
  ip link delete "$SECONDARY_TAP" &>/dev/null || true
  ip link set "$SECONDARY_BRIDGE" down &>/dev/null || true
  ip link delete "$SECONDARY_BRIDGE" type bridge &>/dev/null || true

  # Create bridge and bring it up
  if ! ip link add name "$SECONDARY_BRIDGE" type bridge; then
    warn "Failed to create secondary bridge. $ADD_ERR --cap-add NET_ADMIN"
    return 0
  fi

  ip link set "$SECONDARY_BRIDGE" up

  # Migrate IP from eth1 to bridge
  if [ -n "$ETH1_CIDR" ]; then
    ip addr del "$ETH1_CIDR" dev "$SECONDARY_IFACE" 2>/dev/null || true
    ip addr add "$ETH1_CIDR" dev "$SECONDARY_BRIDGE" || true
  fi

  # Attach eth1 into bridge
  if ! ip link set "$SECONDARY_IFACE" master "$SECONDARY_BRIDGE"; then
    warn "Failed to attach $SECONDARY_IFACE to bridge $SECONDARY_BRIDGE."
    return 0
  fi

  ip link set "$SECONDARY_IFACE" up

  # Restore default gateway via bridge
  if [ -n "$ETH1_GW" ]; then
    ip route del default dev "$SECONDARY_IFACE" &>/dev/null || true
    ip route add default via "$ETH1_GW" dev "$SECONDARY_BRIDGE" &>/dev/null || true
  fi

  # Create TAP device for QEMU
  if ! ip tuntap add dev "$SECONDARY_TAP" mode tap; then
    warn "Failed to create secondary TAP device. $ADD_ERR --device /dev/net/tun"
    return 0
  fi

  if [[ "$SECONDARY_MTU" != "0" && "$SECONDARY_MTU" != "1500" ]]; then
    ip link set dev "$SECONDARY_TAP" mtu "$SECONDARY_MTU" || \
      warn "Failed to set MTU $SECONDARY_MTU on secondary TAP."
  fi

  if ! ip link set "$SECONDARY_TAP" master "$SECONDARY_BRIDGE"; then
    warn "Failed to attach secondary TAP to bridge."
    return 0
  fi

  ip link set "$SECONDARY_TAP" up promisc on

  # Append QEMU secondary netdev + device options
  NET_OPTS+=" -netdev tap,ifname=$SECONDARY_TAP,id=hostnet1,script=no,downscript=no"

  if [ -c /dev/vhost-net ]; then
    { exec 41<>/dev/vhost-net; rc=$?; } 2>/dev/null || :
    (( rc == 0 )) && NET_OPTS+=",vhost=on,vhostfd=41"
  fi

  NET_OPTS+=" -device $SECONDARY_ADAPTER,id=net1,netdev=hostnet1,romfile=,mac=$SECONDARY_MAC"

  [[ "$SECONDARY_MTU" != "0" && "$SECONDARY_MTU" != "1500" ]] && \
    NET_OPTS+=",host_mtu=$SECONDARY_MTU"

  [[ "$DEBUG" == [Yy1]* ]] && echo "Secondary network configured successfully. MAC: $SECONDARY_MAC"

else

  warn "Interface '$SECONDARY_IFACE' was not detected. Skipping secondary RadminVPN network."

fi

return 0
