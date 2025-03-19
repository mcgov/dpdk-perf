#! /bin/bash

# NOTE: run this on the receiver VM
SCRIPT_DIR=$(dirname "$0")
DEVICE_NAME="eth1"
OPTIONS="n"
LONGOPTIONS="nic:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 -n|--nic eth1"
            exit 0
            ;;
        -n|--nic)
            DEVICE_NAME="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            exit 3
            ;;
    esac
done

MANA_MAC="$(cat /sys/class/net/"$DEVICE_NAME"/address)"

./setup/enable_2mb_hugepages.sh
./scripts/setup/setup-netvsc-pmd.sh "$DEVICE_NAME"

sudo ufw disable

sudo dpdk-testpmd -l 3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47 --vdev="7870:00:00.0,mac=$MANA_MAC" -- --forward-mode=rxonly --auto-start   --txd=2048 --rxd=2048 --txq=8 --rxq=8 --stats 2   --txonly-multi-flow --nb-cores=16 --port-numa-config="(1,0)"