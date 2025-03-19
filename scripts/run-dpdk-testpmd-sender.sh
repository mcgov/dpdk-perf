#! /bin/bash

# NOTE: run this on the sender VM
# 
SCRIPT_DIR=$(dirname "$0")
DEVICE_NAME="eth1"
SENDER=""
RECEIVER=""
OPTIONS="n:s:r:"
LONGOPTIONS="nic:,sender,receiver"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 -n|--nic eth1 -s|--sender 10.0.1.4 -r|--receiver 10.0.1.5"
            exit 0
            ;;
        -n|--nic)
            DEVICE_NAME="$2"
            shift 2
            ;;
        -s|--sender)
            SENDER_IP="$2"
            shift 2
            ;;
        -r|--receiver)
            export RECEIVER_IP="$2"
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

if [[ -z "$SENDER" ]] || [[ -z "$RECEIVER" ]]; then
    echo "Must provide a sender and receiver ip with -s and -r" 1>&2;
    exit 1
fi

MANA_MAC="$(cat /sys/class/net/"$DEVICE_NAME"/address)"

./setup/enable_2mb_hugepages.sh
./scripts/setup/setup-netvsc-pmd.sh "$DEVICE_NAME"

sudo ufw disable

sudo dpdk-testpmd -l 3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47 --vdev="7870:00:00.0,mac=$MANA_MAC" -- --forward-mode=txonly --auto-start   --txd=2048 --txq=4 --rxq=4 --stats 2 --tx-ip="10.0.1.4,10.0.1.5"  --txonly-multi-flow --nb-cores=8 --port-numa-config="(1,0)"