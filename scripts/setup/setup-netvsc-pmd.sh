#! /bin/bash

# This script is for azure VMs with accelerated networking.
# The script ensures uio_hv_generic is loaded and 
# binds the 'synthetic' interface to uio_hv_generic.
# 
# For MANA VMs, the script also sets the interface to 'down'
# The goal with this is to prevent the kernel from managing the device.

# invoke as $0 [device_name]
# The script will use eth1 as a default interface name if none
# is provided.

# author: github.com/mcgov

DEVICE_NAME="$1"
if [[ -z "$DEVICE_NAME" ]]; then
    DEVICE_NAME="eth1"
fi
ETH_GUID=$(basename "$(readlink /sys/class/net/"$DEVICE_NAME"/device)")

if [[ -n $(lspci -d 1414:00ba:0200) ]]; then
    # mana is available
    sudo modprobe mana_ib || { \
        echo "Could not load mana_ib, try installing linux-modules-extra-azure" 1>&2 
        exit 1;
    }
else
    echo "Script requires a MANA VM" 1>&2
    exit 1;
fi

## should check if this has already been set up, just ignore failure for now
# shellcheck disable=SC2015
lsmod | grep -q uio_hv_generic \
&& echo "skipping enable uio" \
|| { 
    sudo modprobe uio_hv_generic \
    && echo "f8615163-df3e-46c5-913f-f2d2f965ed0e" \
    | sudo tee "/sys/bus/vmbus/drivers/uio_hv_generic/new_id" ;
} 
# shellcheck disable=SC2015
sudo ip link set "$DEVICE_NAME" down \
&& echo "$ETH_GUID" | sudo tee /sys/bus/vmbus/drivers/hv_netvsc/unbind \
&& echo "$ETH_GUID" | sudo tee /sys/bus/vmbus/drivers/uio_hv_generic/bind \
 || { 
    echo "Could not setup netvsc pmd!";
    exit 1; 
}
exit 0;