# kvm-bench
Support to run performance on X86_64/ARM rapidly.

## Prerequisites
```bash
dnf install sysstat numactl qemu-system-x86 libcgroup-tools -y
```

## Install
```bash
curl -sL https://newgh.smartx.com/raw/fengli/kvm-bench/main/install.sh | bash
```

or git clone this repo.

## Usage

```bash
./kvm_bench.sh [TYPE=OPTIONS[ ...]]
```
The test results will be stored under ./test-results/

For more details, see in
```bash
./kvm_bench.sh -h
```

Examples:
```bash
QEMU_CPU=4 ./kvm_bench.sh modes=4k/randread local-blk=/dev/nullb0 jobs=1 iodepth=128

./kvm_bench.sh spdk-vhost-blk=/dev/nullb1,/dev/nullb2,/dev/nullb3,/dev/nullb4,/dev/nullb5,/dev/nullb6

DEBUG=1 ./kvm_bench.sh spdk-vhost-scsi=/dev/nullb1
```
