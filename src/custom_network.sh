#!/usr/bin/env bash

# Secondary network configuration addition (RadminVPN - eth1)


if [ -d "/sys/class/net/eth1" ]; then
    echo "Configuring secondary network (eth1) for KVM..."
    
    # Gerar um MAC address único para a segunda interface
    MAC2=$(echo "eth1-$HOSTNAME" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
    
    # Salvar o IP e rota originais da eth1 (se houver)
    ETH1_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' || true)
    ETH1_GW=$(ip route | grep "default.*eth1" | awk '{print $3}' || true)
    
    # Criar uma bridge e adicionar eth1
    ip link add name br1 type bridge
    ip link set br1 up
    
    # Mover o IP da eth1 para a bridge
    if [ -n "$ETH1_IP" ]; then
        ip addr del "$ETH1_IP" dev eth1
        ip addr add "$ETH1_IP" dev br1
    fi
    ip link set eth1 master br1
    
    # Restaurar a rota default via bridge se existia
    if [ -n "$ETH1_GW" ]; then
        ip route add default via "$ETH1_GW" dev br1 2>/dev/null || true
    fi
    
    # Criar um TAP device (usa /dev/net/tun que já está exposto no compose)
    ip tuntap add dev tap1 mode tap
    ip link set tap1 master br1
    ip link set tap1 up
    
    # Adicionar os parâmetros ao QEMU usando o TAP diretamente
    ARGS+=" -netdev tap,ifname=tap1,id=hostnet1,script=no,downscript=no -device virtio-net-pci,netdev=hostnet1,id=net1,mac=${MAC2^^}"
    
    echo "Secondary network was created sucessfully. MAC: ${MAC2^^}"
else
    echo "Interface eth1 not found. Skipping second network configuration."
fi
