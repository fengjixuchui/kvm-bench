#!/bin/bash

function p() {
    echo "$@" >> /tmp/fio-cmds.txt
    $@
}

printf "%-30s | %-20s | %-10s | %-10s\\n" "pattern" "bandwidth(MiB/s)" "iops" "latency(us)" | tee /tmp/fio-data.txt
printf "%-30s | %-20s | %-10s | %-10s\\n" ":-" "-:" "-:" "-:" | tee -a /tmp/fio-data.txt

run_fio() {
    local mode=$1
    local iodepth=$2
    local bs=$3
    local dev=$4
    local jobs=$5

    p fio --bs=$bs --iodepth=$iodepth --numjobs=$jobs --thread \
            --rw=$mode --name=async --filename=$dev \
            --ioengine=libaio \
            --gtod_reduce=0 --group_reporting \
            --time_based --runtime=$runtime \
            --direct=1 --minimal | awk -F';' -v pattern="${bs}-${mode}-q${iodepth}-j${jobs}" '{printf "%-30s | %-20d | %-10s | %-10s\\n", pattern,($7+$48)/1024,$8+$49,$40+$81}' | tee -a /tmp/fio-data.txt
    sync
    echo 3 > /proc/sys/vm/drop_caches
    sleep 1
}

