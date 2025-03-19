#! /bin/bash

# allocate a bunch of 2MB hugepages on all numa nodes
echo '4096' | sudo tee /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages
