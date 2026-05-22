#!/usr/bin/env bash
set -Eeuo pipefail

# ######################################
#  Secondary Network Configuration
#  RadminVPN / eth1 / QEMU integration
# ######################################

: "${SECONDARY_MAC:=""}"
: "${SECONDARY_IFACE:="eth1"}"
: "${SECONDARY_TAP:="tap1"}"
: "${SECONDARY_BRIDGE:="br1"}"
: "${SECONDARY_ADAPTER:="${ADAPTER:-virtio-net-pci}"}"

: "${SECONDARY_NET_IP:=""}"
: "${SECONDARY_NET_MAC:="$SECONDARY_MAC"}"
: "${SECONDARY_NET_HOST:="${VM_NET_HOST:-$APP}"}"
: "${SECONDARY_NET_MASK:="255.255.255.0"}"

# ######################################
#  Functions
# ######################################

getSecondaryInfo() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Detecting secondary network interface..."

  # Validate interface existence
  if [ ! -d "/sys/class/net/$SECONDARY_IFACE" ]; then
    warn "Secondary interface '$SECONDARY_IFACE' was not found, skipping RadminVPN network."
    return 1
  fi

  local nic bus result

  result=$(ethtool -i "$SECONDARY_IFACE" 2>/dev/null || true)
  nic=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{print $2}' || true)
  bus=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $2}' || true)

  if [[ "${bus,,}" != "" && "${bus,,}" != "n/a" && "${bus,,}" != "tap" ]]; then
    [[ "$DEBUG" == [Yy1]* ]] && info "Secondary BUS: $bus"
    warn "Secondary interface '$SECONDARY_IFACE' does not appear to be a virtual interface, skipping."
    return 1
  fi

  SECONDARY_CIDR=$(ip -4 addr show "$SECONDARY_IFACE" | awk '/inet / {print $2}' | head -n1 || true)
  SECONDARY_GW=$(ip route | awk "/default.*$SECONDARY_IFACE/ {print \$3}" | head -n1 || true)

  SECONDARY_IP=""
  SECONDARY_MASK_BITS=""

  if [ -n "$SECONDARY_CIDR" ]; then
    SECONDARY_IP="${SECONDARY_CIDR%/*}"
    SECONDARY_MASK_BITS="${SECONDARY_CIDR#*/}"
  fi

  # Resolve MTU from secondary interface if not explicitly set
  local mtu2=""
  if [ -f "/sys/class/net/$SECONDARY_IFACE/mtu" ]; then
    mtu2=$(< "/sys/class/net/$SECONDARY_IFACE/mtu")
  fi
  : "${SECONDARY_MTU:="${mtu2:-0}"}"

  # Generate deterministic MAC for the QEMU secondary NIC
  # Mirrors the same md5sum method used for VM_NET_MAC in network.sh
  if [ -z "$SECONDARY_MAC" ]; then
    local file="$STORAGE/$PROCESS.mac2"
    [ -s "$file" ] && SECONDARY_MAC=$(<"$file")
    SECONDARY_MAC="${SECONDARY_MAC//[![:print:]]/}"
    if [ -z "$SECONDARY_MAC" ]; then
      SECONDARY_MAC=$(echo "${HOST}-${SECONDARY_IFACE}" | md5sum | \
        sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
      echo "${SECONDARY_MAC^^}" > "$file"
      ! setOwner "$file" && warn "Failed to set owner for \"$file\"."
    fi
  fi

  SECONDARY_NET_MAC="${SECONDARY_MAC^^}"
  SECONDARY_NET_MAC="${SECONDARY_NET_MAC//-/:}"

  if [[ ${#SECONDARY_NET_MAC} == 12 ]]; then
    local m="$SECONDARY_NET_MAC"
    SECONDARY_NET_MAC="${m:0:2}:${m:2:2}:${m:4:2}:${m:6:2}:${m:8:2}:${m:10:2}"
  fi

  if [[ ${#SECONDARY_NET_MAC} != 17 ]]; then
    error "Invalid secondary MAC address: '$SECONDARY_NET_MAC', should be 12 or 17 digits long!"
    return 1
  fi

  if [[ "$DEBUG" == [Yy1]* ]]; then
    info "Secondary interface: $SECONDARY_IFACE"
    info "Secondary bridge:    $SECONDARY_BRIDGE"
    info "Secondary TAP:       $SECONDARY_TAP"
    info "Secondary IP:        ${SECONDARY_IP:-<none>}"
    info "Secondary Gateway:   ${SECONDARY_GW:-<none>}"
    info "Secondary MAC:       $SECONDARY_NET_MAC"
    info "Secondary MTU:       $SECONDARY_MTU"
    echo
  fi

  return 0
}

cleanUpSecondary() {

  # Remove any lingering tap/bridge from a previous run
  if [[ -d "/sys/class/net/$SECONDARY_TAP" ]]; then
    info "Lingering secondary TAP interface will be removed..."
    ip link set "$SECONDARY_TAP" down promisc off &>/dev/null || true
    ip link delete "$SECONDARY_TAP" &>/dev/null || true
  fi

  if [[ -d "/sys/class/net/$SECONDARY_BRIDGE" ]]; then
    info "Lingering secondary bridge will be removed..."
    ip link set "$SECONDARY_BRIDGE" down &>/dev/null || true
    ip link delete "$SECONDARY_BRIDGE" type bridge &>/dev/null || true
  fi

  return 0
}

configureSecondaryNAT() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring secondary NAT bridge for RadminVPN (eth1)..."

  # ── Bridge creation ──────────────────────────────────────────────────────────

  { ip link add name "$SECONDARY_BRIDGE" type bridge; rc=$?; } || :

  if (( rc != 0 )); then
    warn "Failed to create secondary bridge '$SECONDARY_BRIDGE'. $ADD_ERR --cap-add NET_ADMIN"
    return 1
  fi

  ip link set "$SECONDARY_BRIDGE" up

  # ── Migrate IP/GW from eth1 into the bridge ──────────────────────────────────
  # Mirrors the addr-migration pattern used for VM_NET_BRIDGE in configureNAT()

  if [ -n "$SECONDARY_CIDR" ]; then
    ip addr del "$SECONDARY_CIDR" dev "$SECONDARY_IFACE" 2>/dev/null || true
    if ! ip addr add "$SECONDARY_CIDR" dev "$SECONDARY_BRIDGE"; then
      warn "Failed to assign IP ${SECONDARY_CIDR} to bridge $SECONDARY_BRIDGE."
    fi
  fi

  if [ -n "$SECONDARY_GW" ]; then
    ip route del default dev "$SECONDARY_IFACE" &>/dev/null || true
    ip route add default via "$SECONDARY_GW" dev "$SECONDARY_BRIDGE" &>/dev/null || true
  fi

  # ── Attach eth1 as bridge port ───────────────────────────────────────────────

  if ! ip link set "$SECONDARY_IFACE" master "$SECONDARY_BRIDGE"; then
    warn "Failed to attach '$SECONDARY_IFACE' to bridge '$SECONDARY_BRIDGE'."
    return 1
  fi

  ip link set "$SECONDARY_IFACE" up

  # ── TAP device for QEMU ──────────────────────────────────────────────────────
  # Mirrors ip tuntap + promisc pattern from configureNAT()

  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"

  if [ ! -c /dev/net/tun ]; then
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net
    if mknod /dev/net/tun c 10 200; then
      chmod 666 /dev/net/tun
    fi
  fi

  if [ ! -c /dev/net/tun ]; then
    warn "$tuntap"
    return 1
  fi

  if ! ip tuntap add dev "$SECONDARY_TAP" mode tap; then
    warn "Failed to create secondary TAP device. $ADD_ERR --device /dev/net/tun"
    return 1
  fi

  if [[ "$SECONDARY_MTU" != "0" && "$SECONDARY_MTU" != "1500" ]]; then
    if ! ip link set dev "$SECONDARY_TAP" mtu "$SECONDARY_MTU"; then
      warn "Failed to set MTU $SECONDARY_MTU on secondary TAP."
    fi
  fi

  while ! ip link set "$SECONDARY_TAP" up promisc on; do
    info "Waiting for secondary TAP to become available..."
    sleep 2
  done

  if ! ip link set dev "$SECONDARY_TAP" master "$SECONDARY_BRIDGE"; then
    warn "Failed to attach secondary TAP to bridge."
    return 1
  fi

  # ── Build QEMU -netdev / -device options ────────────────────────────────────
  # Mirrors NET_OPTS construction in configureNAT() and custom_network.sh

  NET_OPTS+=" -netdev tap,id=hostnet1,ifname=$SECONDARY_TAP,script=no,downscript=no"

  if [ -c /dev/vhost-net ]; then
    { exec 41<>/dev/vhost-net; rc=$?; } 2>/dev/null || :
    (( rc == 0 )) && NET_OPTS+=",vhost=on,vhostfd=41"
  fi

  NET_OPTS+=" -device $SECONDARY_ADAPTER,id=net1,netdev=hostnet1,romfile=,mac=$SECONDARY_NET_MAC"

  [[ "$SECONDARY_MTU" != "0" && "$SECONDARY_MTU" != "1500" ]] && \
    NET_OPTS+=",host_mtu=$SECONDARY_MTU"

  [[ "$DEBUG" == [Yy1]* ]] && echo "Secondary RadminVPN NAT bridge initialized successfully."

  return 0
}

closeSecondaryNAT() {

  [[ "$DEBUG" == [Yy1]* ]] && echo "Tearing down secondary RadminVPN network..."

  exec 41<&- || true

  ip link set "$SECONDARY_TAP" down promisc off &>/dev/null || true
  ip link delete "$SECONDARY_TAP" &>/dev/null || true

  ip link set "$SECONDARY_IFACE" nomaster &>/dev/null || true

  ip link set "$SECONDARY_BRIDGE" down &>/dev/null || true
  ip link delete "$SECONDARY_BRIDGE" type bridge &>/dev/null || true

  return 0
}

# ######################################
#  Initialize Secondary Network
# ######################################

# Guard: only run if primary network is active
# (NETWORK=N means even the primary was disabled — no point adding a second NIC)
if [[ "$NETWORK" == [Nn]* ]]; then
  [[ "$DEBUG" == [Yy1]* ]] && echo "Primary network disabled, skipping secondary RadminVPN network."
  return 0
fi

msg="Initializing secondary RadminVPN network (eth1)..."
html "$msg"
[[ "$DEBUG" == [Yy1]* ]] && echo "$msg"

# Collect interface info; if eth1 is absent or unsuitable, skip gracefully
if ! getSecondaryInfo; then
  html "Secondary RadminVPN network skipped."
  return 0
fi

cleanUpSecondary

# Configure bridge + TAP and append QEMU opts
if ! configureSecondaryNAT; then
  closeSecondaryNAT
  warn "Failed to initialize secondary RadminVPN network. Continuing with primary only."
  html "Secondary RadminVPN network initialization failed."
  return 0
fi

html "Secondary RadminVPN network initialized successfully."
return 0