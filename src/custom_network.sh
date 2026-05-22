```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# ######################################
# Secondary Network Configuration
# RadminVPN / eth1 / QEMU integration
# ######################################

: "${SECONDARY_IFACE:="eth1"}"
: "${SECONDARY_BRIDGE:="br1"}"
: "${SECONDARY_TAP:="tap1"}"
: "${SECONDARY_ADAPTER:="$ADAPTER"}"

configureSecondaryNetwork() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring secondary network for RadminVPN..."

  # Validate interface existence
  if [ ! -d "/sys/class/net/$SECONDARY_IFACE" ]; then
    warn "Secondary interface '$SECONDARY_IFACE' was not found."
    return 0
  fi

  # Collect original network information
  local ETH1_IP=""
  local ETH1_MASK=""
  local ETH1_GW=""
  local ETH1_CIDR=""
  local ETH1_MAC=""

  ETH1_CIDR=$(ip -4 addr show "$SECONDARY_IFACE" | awk '/inet / {print $2}' | head -n1 || true)
  ETH1_GW=$(ip route | awk "/default.*$SECONDARY_IFACE/ {print \$3}" | head -n1 || true)

  if [ -n "$ETH1_CIDR" ]; then
    ETH1_IP="${ETH1_CIDR%/*}"
    ETH1_MASK="${ETH1_CIDR#*/}"
  fi

  # Generate deterministic MAC for QEMU secondary NIC
  ETH1_MAC=$(echo "${HOST}-${SECONDARY_IFACE}" | md5sum | \
    sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')

  ETH1_MAC="${ETH1_MAC^^}"

  [[ "$DEBUG" == [Yy1]* ]] && info "Secondary interface: $SECONDARY_IFACE"
  [[ "$DEBUG" == [Yy1]* ]] && info "Bridge: $SECONDARY_BRIDGE"
  [[ "$DEBUG" == [Yy1]* ]] && info "Tap: $SECONDARY_TAP"
  [[ "$DEBUG" == [Yy1]* ]] && info "Secondary MAC: $ETH1_MAC"

  # Cleanup previous interfaces if they exist
  ip link set "$SECONDARY_TAP" down &>/dev/null || true
  ip link delete "$SECONDARY_TAP" &>/dev/null || true

  ip link set "$SECONDARY_BRIDGE" down &>/dev/null || true
  ip link delete "$SECONDARY_BRIDGE" type bridge &>/dev/null || true

  # Create bridge
  if ! ip link add name "$SECONDARY_BRIDGE" type bridge; then
    error "Failed to create secondary bridge."
    return 1
  fi

  # Enable bridge
  ip link set "$SECONDARY_BRIDGE" up

  # Remove IP from eth1 and migrate to bridge
  if [ -n "$ETH1_CIDR" ]; then

    ip addr del "$ETH1_CIDR" dev "$SECONDARY_IFACE" || true
    ip addr add "$ETH1_CIDR" dev "$SECONDARY_BRIDGE" || true

  fi

  # Attach eth1 into bridge
  if ! ip link set "$SECONDARY_IFACE" master "$SECONDARY_BRIDGE"; then
    error "Failed to attach $SECONDARY_IFACE into bridge."
    return 1
  fi

  # Restore gateway if present
  if [ -n "$ETH1_GW" ]; then

    ip route del default dev "$SECONDARY_IFACE" &>/dev/null || true
    ip route add default via "$ETH1_GW" dev "$SECONDARY_BRIDGE" &>/dev/null || true

  fi

  # Create TAP interface for QEMU
  if ! ip tuntap add dev "$SECONDARY_TAP" mode tap; then
    error "Failed to create TAP device for secondary network."
    return 1
  fi

  # MTU consistency
  if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then

    if ! ip link set dev "$SECONDARY_TAP" mtu "$MTU"; then
      warn "Failed to apply MTU to secondary TAP."
    fi

  fi

  # Attach TAP to bridge
  if ! ip link set "$SECONDARY_TAP" master "$SECONDARY_BRIDGE"; then
    error "Failed to attach TAP to bridge."
    return 1
  fi

  # Enable TAP
  if ! ip link set "$SECONDARY_TAP" up promisc on; then
    error "Failed to enable TAP interface."
    return 1
  fi

  # Ensure bridge stays active
  ip link set "$SECONDARY_IFACE" up
  ip link set "$SECONDARY_BRIDGE" up

  # Add QEMU secondary network
  NET_OPTS+=" -netdev tap,id=hostnet1,ifname=$SECONDARY_TAP,script=no,downscript=no"

  # Enable vhost acceleration if available
  if [ -c /dev/vhost-net ]; then

    { exec 41<>/dev/vhost-net; rc=$?; } 2>/dev/null || :

    if (( rc == 0 )); then
      NET_OPTS+=",vhost=on,vhostfd=41"
    fi

  fi

  # Attach second NIC to VM
  NET_OPTS+=" -device $SECONDARY_ADAPTER,id=net1,netdev=hostnet1,romfile=,mac=$ETH1_MAC"

  [[ "$MTU" != "0" && "$MTU" != "1500" ]] && \
    NET_OPTS+=",host_mtu=$MTU"

  [[ "$DEBUG" == [Yy1]* ]] && echo "Secondary RadminVPN network initialized successfully."

  return 0
}

closeSecondaryNetwork() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Cleaning secondary network..."

  ip link set "$SECONDARY_TAP" down &>/dev/null || true
  ip link delete "$SECONDARY_TAP" &>/dev/null || true

  ip link set "$SECONDARY_IFACE" nomaster &>/dev/null || true

  ip link set "$SECONDARY_BRIDGE" down &>/dev/null || true
  ip link delete "$SECONDARY_BRIDGE" type bridge &>/dev/null || true

  return 0
}

# ######################################
# Initialize Secondary Network
# ######################################

configureSecondaryNetwork || {
  error "Failed to initialize secondary RadminVPN network."
  exit 1
}
```
