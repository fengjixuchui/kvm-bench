#!/bin/bash

ip=$1
if [ -z "$ip" ]; then
    echo "Usage: $0 <ip>"
    exit 1
fi
tmux kill-session -t kvm-bench
# select-layout even-horizontal ,even-vertical
tmux new -d -s kvm-bench \; split-window -hf \; split-window -hf \;split-window -hf\; split-window -vf \; split-window -vf \; split-window -vf \; split-window -vf \; select-layout tiled
#tmux new -d -s kvm-bench \; split-window -h \; split-window -v \; select-pane -L \; split-window -v

function run() {
    tmux send-keys -t kvm-bench.$1 "$2" ENTER
}

for i in `seq 1 6`;do
    run $i "ssh root@$ip"
done

function defer() {
for i in `seq 1 6`;do
    #run $i "cd /root/kvm-bench;NUMA=$(($i%1)) SPDK_TGT_CPUMASK='[2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh local-blk=/dev/nullb$i"
    run $i "cd /root/kvm-bench;NUMA=0 SPDK_TGT_CPUMASK='[2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh spdk-vhost-blk=/dev/nullb$i"
    [ $i -eq 1 ] && sleep 3
done
#run 1 "cd /root/kvm-bench;RUN_SPDK=1 QEMU_CPU=4,6 SPDK_TGT_CPUMASK='[0, 2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh spdk-vhost-blk=/dev/nullb0"
#sleep 3
#run 2 "cd /root/kvm-bench;RUN_SPDK=0 QEMU_CPU=8,10 SPDK_TGT_CPUMASK='[2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh spdk-vhost-blk=/dev/nullb1"
#sleep 1
#run 3 "cd /root/kvm-bench;RUN_SPDK=0 QEMU_CPU=12,14 SPDK_TGT_CPUMASK='[2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh spdk-vhost-blk=/dev/nullb2"
#sleep 1
#run 4 "cd /root/kvm-bench;RUN_SPDK=0 QEMU_CPU=14,16 SPDK_TGT_CPUMASK='[2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh spdk-vhost-blk=/dev/nullb3"
#sleep 1
#run 5 "cd /root/kvm-bench;RUN_SPDK=0 QEMU_CPU=16,18 SPDK_TGT_CPUMASK='[2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh spdk-vhost-blk=/dev/nullb4"
#sleep 1
#run 6 "cd /root/kvm-bench;RUN_SPDK=0 QEMU_CPU=18,20 SPDK_TGT_CPUMASK='[2]' SIZE_HP=14 DEBUG=1 MEM=2048 CPU=2 ./kvm_bench.sh spdk-vhost-blk=/dev/nullb5"

sleep 10
for i in `seq 1 6`;do
    run $i "fio --bs=4k --iodepth=128 --numjobs=1 --thread --rw=randread --name=async --filename=/dev/vda --ioengine=libaio --gtod_reduce=1 --group_reporting --time_based --runtime=1000 --direct=1"
done
}
defer &
tmux a -t kvm-bench
