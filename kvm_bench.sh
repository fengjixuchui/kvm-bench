#!/bin/bash
#set -x

ulimit -l unlimited
root_dir=$(readlink -f $(dirname $0))
cpu=${CPU:-2}
mem=${MEM:-2048}
hugepage_size=""
hugepage_dir=""
raw_hugepages=""
new_hugepages=""

reconnect=${RECONNECT:-1}
iothread=${IOTHREAD:-1}
numa=${NUMA:-0}
portal=${PORTAL:-127.0.0.1}

qemu=${QEMU}
qemu_bin=""
kernel=${KERNEL}
initrd=${INITRD}
qemu_prompt=${QEMU_PROMPT:-"rapido1:/root/blktests#"}
qemu_pid=""
qemu_cpu=${QEMU_CPU:-""}
enable_perf=${PERF:-0}
perf_pid=""
debug=${DEBUG:-0}
size_hp=${SIZE_HP:-0}

spdk_sock=${SPDK_SOCK:-"${root_dir}/tmp/spdk.sock"}
spdk_vhost_sock=${SPDK_VHOST_SOCK:-"${root_dir}/tmp"}
run_spdk=${RUN_SPDK:-1}
spdk_rpc=""
spdk_tgt=""
spdk_tgt_cpumask=${SPDK_TGT_CPUMASK:-$(numactl -H | grep "node ${numa} cpus" | awk -F: '{print $2}' | awk '{printf "[%d,%d]\n",$1,$2}')}
spdk_scsi_controller_cpumask=${SPDK_SCSI_CPUMASK:-""}
spdk_blk_controller_cpumask=${SPDK_BLK_CPUMASK:-""}
spdk_tgt_pid=""
vhost_queues=${VHOST_QUEUES:-2}

spdk_inited=""
zbs_vhost_scsi_init_args=""
zbs_vhost_blk_init_args=""

enable_test_zbs_vhost=""
enable_warmup=${WARMUP:-0}
scsi_test_disks=()
blk_test_disks=()
jobs=(1 2)
iodepth=(1 128)
bs_rw=(4k-randread 4k-randwrite 256k-randread 256k-randwrite)
runtime=10

disks=""
extra=""

# Color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

function red {
    printf "${RED}$@${NC}\n"
}

function green {
    printf "${GREEN}$@${NC}\n"
}

function yellow {
    printf "${YELLOW}$@${NC}\n"
}

print_kv() {
    str="$(printf "%-30s: %s\n" "$1" "$2")"
    #yellow "$str"
    echo "$str"
}

print_title() {
    green "✅ $1"
}

function env_check() {
  print_title "ENV"
  arch=$(uname -m)

  release=$(uname -r)
  dist=""
  if [[ "$release" =~ "el" ]]; then
    dist="el7"
  elif [[ "$release" =~ "oe" ]]; then
    dist="oe"
  elif [[ "$release" =~ "fc36" ]]; then
    dist="fc36"
  fi
  spdk_tgt="${root_dir}/${arch}/${dist}/spdk_tgt"
  spdk_rpc="${root_dir}/rpc.py -s ${spdk_sock}"

  if [ -x "${qemu}" ]; then
    qemu_bin=${QEMU}
  else
    qemu_possible=(/usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-"${arch}")
    for item in "${qemu_possible[@]}"; do
      if [ -x "${item}" ]; then
        qemu_bin=${item}
        break
      fi
    done
  fi
  if [ -z "${qemu_bin}" ]; then
    echo "Can not find QEMU! Use QEMU=/path/to/qemu to specify" && exit 1
  fi

  if ! [ -f "$kernel" ]; then
    kernel="${root_dir}/${arch}/guest/bzImage"
  fi
  if ! [ -f "$initrd" ]; then
    initrd="${root_dir}/${arch}/guest/initrd"
  fi

  if [ "${arch}" = "aarch64" ]; then
      extra="$extra -bios /usr/share/edk2.git/aarch64/QEMU_EFI.fd -cpu host -enable-kvm -machine virt-rhel7.6.0,accel=kvm,usb=off,dump-guest-core=off,gic-version=3 "
      kernel="${root_dir}/${arch}/guest/Image.gz"
  else
    extra="$extra -cpu host -enable-kvm "
  fi

  print_kv "ARCH" "${arch}"
  print_kv "OS" "${dist}"
  print_kv "Qemu on NUMA" "${numa}"
  print_kv "CPU" "${cpu}"
  print_kv "MEM(MiB)" "${mem}"
  print_kv "RUN SPDK" "${run_spdk}"
  print_kv "SPDK_TGT_CPUMASK" "${spdk_tgt_cpumask}"
  print_kv "QEMU" "${qemu_bin}"
  if [ -n "$qemu_cpu" ]; then
    print_kv "QEMU_CPU" "$qemu_cpu"
  fi
  print_kv "KERNEL" "${kernel}"
  print_kv "INITRD" "${initrd}"
  print_kv "NUMA ${numa}" "$(numactl -H | grep "node ${numa} cpus" | awk -F': ' '{print $2}')"
  print_kv "SIZE_HP" "${size_hp} GiB"
}

function disk_check() {
  if ! [ -b "$1" ]; then
    echo "Can not find $1, check the path!" && exit 1
  fi
}

function spdk_init() {
  [ ${run_spdk} -eq 0 ] && return
  [ -n "$(pidof spdk_tgt)" ] && return
  [ "${spdk_inited}" = "true" ] && return

  print_title "Start SPDK Target"
  local log=${root_dir}/tmp/spdk_tgt.log.$(date +%Y%m%d-%H%M%S)
  echo "${spdk_tgt} -r ${spdk_sock} -S ${spdk_vhost_sock} -m ${spdk_tgt_cpumask} --huge-unlink" >${log}
  setsid cgexec -g cpuset:/ "${spdk_tgt}" -r "${spdk_sock}" -S "${spdk_vhost_sock}" -m "${spdk_tgt_cpumask}" --huge-unlink \
    -L iscsi -L vhost -L vhost_blk -L vhost_blk_data -L vhost_ring >>${log} 2>&1 &
  spdk_tgt_pid=$!
  sleep 1
  spdk_inited=true
}

function add_hugepages() {
  local free_hugepages=""
  local need_hugepages=""
  local spdk_mem=""

  if [ -n "$hugepage_size" ]; then
    return # run this only once
  fi

  hugepage_size=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
  print_kv "HUGEPAGESIZE" "${hugepage_size}kiB"
  hugepage_dir="/sys/devices/system/node/node${numa}/hugepages/hugepages-${hugepage_size}kB"

  if [ $size_hp -ne 0 ];then
    raw_hugepages=$(cat "${hugepage_dir}/nr_hugepages")
    new_hugepages=$((size_hp * 1024 * 1024 / hugepage_size))
    echo $new_hugepages > "${hugepage_dir}/nr_hugepages"
    echo "Change nr_hugepages ${raw_hugepages} --> ${new_hugepages} temporarily on NUMA${numa}."
  else
    if [ "${arch}" = "aarch64" ]; then
      spdk_mem="2048"
    else
      spdk_mem="1024"
    fi
    free_hugepages=$(cat "${hugepage_dir}/free_hugepages")
    # add 1024MB for spdk_tgt to use and covert to KB
    need_hugepages=$(((mem + spdk_mem) * 1024 / hugepage_size))
    if [ ${free_hugepages} -ge ${need_hugepages} ]; then
      echo "Nothing to do with hugepage."
    else
      raw_hugepages=$(cat "${hugepage_dir}/nr_hugepages")
      new_hugepages=$((need_hugepages - free_hugepages + raw_hugepages))
      echo $new_hugepages > "${hugepage_dir}/nr_hugepages"
      echo "Change nr_hugepages ${raw_hugepages} --> ${new_hugepages} temporarily on NUMA${numa}."
    fi
  fi

  extra=" $extra -object memory-backend-file,id=mem0,size=${mem}M,mem-path=/dev/hugepages,share=on -numa node,memdev=mem0 -mem-prealloc"
}

function spdk_iscsi_init() {
  $spdk_rpc iscsi_create_portal_group 1 0.0.0.0:3280
  $spdk_rpc iscsi_create_initiator_group 2 ANY 192.0.0.0/8
  $spdk_rpc iscsi_create_initiator_group 3 ANY 127.0.0.0/8
}

function spdk_create_iscsi() {
  local disk_name="${1##*/}"
  $spdk_rpc bdev_aio_create "$1" iscsi_"${disk_name}"
  $spdk_rpc iscsi_create_target_node spdk-iscsi-"${disk_name}" spdk-iscsi-"${disk_name}" "iscsi_${disk_name}:0" "1:2 1:3" 128 -d
}

function spdk_create_vhost_scsi() {
  local cpumask=""
  local disk_name="${1##*/}"
  if [ -n "${spdk_scsi_controller_cpumask}" ]; then
    cpumask="--cpumask ${spdk_scsi_controller_cpumask}"
  fi
  $spdk_rpc bdev_aio_create "$1" vhost_scsi_"${disk_name}"
  $spdk_rpc vhost_create_scsi_controller ${cpumask} spdk-vhost-scsi."${disk_name}"
  $spdk_rpc vhost_scsi_controller_add_target spdk-vhost-scsi."${disk_name}" 0 vhost_scsi_"${disk_name}"
}

function spdk_create_vhost_blk() {
  local cpumask=""
  local disk_name="${1##*/}"
  $spdk_rpc bdev_aio_create "$1" vhost_blk_"${disk_name}"
  if [ -n "${spdk_blk_controller_cpumask}" ]; then
      cpumask="--cpumask $spdk_blk_controller_cpumask"
  fi
  $spdk_rpc vhost_create_blk_controller ${cpumask} spdk-vhost-blk."${disk_name}" vhost_blk_"${disk_name}"
}

function zbs_create_vhost() {
  zbs-procurator bdev bdev_zbs_create "$1"
  zbs-procurator controller create "$2" "$1" -t "$3"
}

function zbs_delete_vhost() {
  zbs-procurator controller remove -y "$1"
}

# parse disks
###########################################################################################
local_disk_cnt=0
bootindex=1
function create_local_disk() {
  id="my-local-${local_disk_cnt}"

  file_type=raw
  [[ $1 =~ "qcow2" ]] && file_type=qcow2
  disks=" $disks -drive file=$1,format=$file_type,cache=none,aio=native,if=none,id=drive-$id,file.locking=off -device virtio-blk-pci,scsi=off,drive=drive-$id,id=$id,bus=pci.1,addr=0x${bootindex},bootindex=${bootindex}"
  local_disk_cnt=$((local_disk_cnt + 1))
  bootindex=$((bootindex + 1))
}

scsi_disk_cnt=0
function create_scsi_disk() {
  id="my-scsi0-0-0-${scsi_disk_cnt}"

  disks=" $disks -drive file.driver=iscsi,file.portal=${portal}:$1,file.target=$2,file.lun=$3,file.transport=tcp,format=raw,cache=none,aio=native,if=none,id=drive-$id -device scsi-hd,bus=scsi0.0,channel=0,scsi-id=0,lun=$scsi_disk_cnt,drive=drive-$id,id=$id,bootindex=${bootindex}"
  scsi_disk_cnt=$((scsi_disk_cnt + 1))
  bootindex=$((bootindex + 1))
}

blk_disk_cnt=1
function create_blk_disk() {
  id="my-blk-${blk_disk_cnt}"

  [ $iothread -eq 1 ] && disks=" $disks -object iothread,id=blk-iothread${blk_disk_cnt} "
  disks=" $disks -drive file.driver=iscsi,file.portal=${portal}:$1,file.target=$2,file.lun=$3,file.transport=tcp,format=raw,cache=none,aio=native,if=none,id=drive-$id -device virtio-blk-pci,scsi=off,drive=drive-$id,id=$id,bus=pci.1,addr=0x${bootindex},bootindex=${bootindex}"
  [ $iothread -eq 1 ] && disks="$disks,iothread=blk-iothread${blk_disk_cnt} "
  blk_disk_cnt=$((blk_disk_cnt + 1))
  bootindex=$((bootindex + 1))
}

vhost_scsi_disk_cnt=0
function create_vhost_scsi_disk() {
  id="my-vhost-scsi-${vhost_scsi_disk_cnt}"

  disks=" $disks -device vhost-user-scsi-pci,chardev=$id,id=$id,bus=pci.1,addr=0x${bootindex},bootindex=${bootindex},num_queues=${vhost_queues}"
  disks=" $disks -chardev socket,id=$id,path=$1"
  vhost_blk_disk_cnt=$((vhost_scsi_disk_cnt + 1))
  bootindex=$((bootindex + 1))
}

vhost_blk_disk_cnt=0
function create_vhost_blk_disk() {
  id="my-vhost-blk-${vhost_blk_disk_cnt}"

  disks=" $disks -device vhost-user-blk-pci,chardev=$id,id=$id,bus=pci.1,addr=0x${bootindex},bootindex=${bootindex},num-queues=${vhost_queues}"
  disks=" $disks -chardev socket,id=$id,path=$1"
  [ $reconnect -eq 1 ] && disks="$disks,reconnect=1 "
  vhost_blk_disk_cnt=$((vhost_blk_disk_cnt + 1))
  bootindex=$((bootindex + 1))
}

function parse_args() {
  if ! [ -d "${root_dir}/test-results" ]; then
    mkdir "${root_dir}"/test-results
  fi
  if ! [ -d "${root_dir}/tmp" ]; then
    mkdir "${root_dir}"/tmp
  fi

  modprobe null_blk nr-devices=10 hw_queue_depth=256 submit_queues=256 queue_mode=2

  for word in $@; do
    IFS='=' read -r key val <<<"$word"
    if [ "$key" = "local-blk" ]; then
      IFS=',' read -ra items <<<"$val"
      for i in "${items[@]}"; do
        disk_check "$i"
        # replace '/' to '-' in device name, so we can create test result file named with device name
        blk_test_disks[${#blk_test_disks[@]}]="local-blk${i//\//-}"
        create_local_disk "$i"
      done
    fi

    if [[ "$key" =~ "zbs-iscsi" ]]; then
      disk_type=${key##*-}
      IFS=',' read -ra items <<<"$val"
      if [ "$disk_type" = "scsi" ]; then
        for item in "${items[@]}"; do
          IFS='/' read -r target lun <<<"$item"
          scsi_test_disks[${#scsi_test_disks[@]}]="zbs-iscsi-scsi-${target}-${lun}"
          create_scsi_disk 3261 "iqn.2016-02.com.smartx:system:${target}" "$lun"
        done
      elif [ "$disk_type" = "blk" ]; then
        for item in "${items[@]}"; do
          IFS='/' read -r target lun <<<"$item"
          blk_test_disks[${#blk_test_disks[@]}]="zbs-iscsi-blk-${target}-${lun}"
          create_blk_disk 3261 "iqn.2016-02.com.smartx:system:${target}" "$lun"
        done
      fi
    fi

    if [[ "$key" =~ "spdk-iscsi" ]]; then
      disk_type=${key##*-}
      spdk_init
      spdk_iscsi_init
      IFS=',' read -ra items <<<"$val"
      if [ "$disk_type" = "scsi" ]; then
        for i in "${items[@]}"; do
          disk_check "$i"
          spdk_create_iscsi "$i"
          scsi_test_disks[${#scsi_test_disks[@]}]="spdk-iscsi-scsi${i//\//-}"
          create_scsi_disk 3280 iqn.2016-06.io.spdk:spdk-iscsi-"${i##*/}" 0
        done
      elif [ "${disk_type}" = "blk" ]; then
        for i in "${items[@]}"; do
          disk_check "$i"
          spdk_create_iscsi "$i"
          blk_test_disks[${#blk_test_disks[@]}]="spdk-iscsi-blk${i//\//-}"
          create_blk_disk 3280 iqn.2016-06.io.spdk:spdk-iscsi-"${i##*/}" 0
        done
      fi
    fi

    if [[ "$key" =~ "spdk-vhost" ]]; then
      disk_type=${key##*-}
      add_hugepages
      spdk_init
      IFS=',' read -ra items <<<"$val"
      if [ "$disk_type" = "scsi" ]; then
        for i in "${items[@]}"; do
          disk_check "$i"
          # replace '/' to '-' in device name, so we can create test result file named with device name
          scsi_test_disks[${#scsi_test_disks[@]}]="spdk-vhost-scsi${i//\//-}"
          spdk_create_vhost_scsi "$i"
          create_vhost_scsi_disk "${spdk_vhost_sock}/spdk-vhost-scsi.${i##*/}"
        done
      elif [ "$disk_type" = "blk" ]; then
        for i in "${items[@]}"; do
          disk_check "$i"
          blk_test_disks[${#blk_test_disks[@]}]="spdk-vhost-blk${i//\//-}"
          spdk_create_vhost_blk "$i"
          create_vhost_blk_disk "${spdk_vhost_sock}/spdk-vhost-blk.${i##*/}"
        done
      fi
    fi

    if [[ "$key" =~ "zbs-vhost" ]]; then
      disk_type=${key##*-}
      enable_test_zbs_vhost=true
      add_hugepages
      if [ "${disk_type}" = "scsi" ]; then
        zbs_vhost_scsi_init_args="${val}"
        IFS=',' read -ra items <<<"$val"
        for item in "${items[@]}"; do
          IFS='/' read -r target lun <<<"$item"
          zbs_create_vhost "kvm-bench#${target}#${lun}" "zbs-vhost-scsi.${target}.${lun}" "scsi"
          scsi_test_disks[${#scsi_test_disks[@]}]="zbs-vhost-scsi-${target}-${lun}"
          create_vhost_scsi_disk "/var/lib/zbs/aurorad/zbs-vhost-scsi.${target}.${lun}"
        done
      elif [ "${disk_type}" = "blk" ]; then
        zbs_vhost_blk_init_args="${val}"
        IFS=',' read -ra items <<<"$val"
        for item in "${items[@]}"; do
          IFS='/' read -r target lun <<<"$item"
          zbs_create_vhost "kvm-bench#${target}#${lun}" "zbs-vhost-blk.${target}.${lun}" "blk"
          blk_test_disks[${#blk_test_disks[@]}]="zbs-vhost-blk-${target}-${lun}"
          create_vhost_blk_disk "/var/lib/zbs/aurorad/zbs-vhost-blk.${target}.${lun}"
        done
      fi
    fi

    if [ "$key" = "jobs" ]; then
      jobs=()
      IFS=',' read -ra items <<<"$val"
      for i in "${items[@]}"; do
        jobs[${#jobs[@]}]=$i;
      done
    fi

    if [ "$key" = "iodepth" ]; then
      iodepth=()
      IFS=',' read -ra items <<<"$val"
      for i in "${items[@]}"; do
        iodepth[${#iodepth[@]}]=$i
      done
    fi

    if [ "$key" = "modes" ]; then
      bs_rw=()
      IFS=',' read -ra items <<<"$val"
      for i in "${items[@]}"; do
        IFS='/' read -r bs rw <<<"$i"
        IFS='+' read -ra bs_items <<<"$bs"
        IFS='+' read -ra rw_items <<<"$rw"
        for j in "${bs_items[@]}"; do
          for k in "${rw_items[@]}"; do
            bs_rw[${#bs_rw[@]}]="$j"-"$k"
          done
        done
      done
    fi

    if [ "$key" = "runtime" ]; then
      runtime=${val}
    fi

  done
}

function clean() {
  print_title "Cleaning up"
  # wait QEMU to quit
  if [ -n "$qemu_pid" ]; then
    wait $qemu_pid
  fi

  if [ -n "$spdk_tgt_pid" ]; then
    kill "$spdk_tgt_pid"
    wait $spdk_tgt_pid
  fi

  if [ "$enable_test_zbs_vhost" = "true" ]; then
    IFS=',' read -ra items <<<"$zbs_vhost_scsi_init_args"
    for item in "${items[@]}"; do
      IFS='/' read -r target lun <<<"$item"
      zbs_delete_vhost "zbs-vhost-scsi.${target}.${lun}"
    done
    IFS=',' read -ra items <<<"$zbs_vhost_blk_init_args"
    for item in "${items[@]}"; do
      IFS='/' read -r target lun <<<"$item"
      zbs_delete_vhost "zbs-vhost-blk.${target}.${lun}"
    done
  fi

  if [ -n "${raw_hugepages}" ]; then
    echo "Reset nr_hugepages ${new_hugepages} --> ${raw_hugepages} on NUMA${numa}."
    echo ${raw_hugepages} > "${hugepage_dir}/nr_hugepages"
  fi

  modprobe -r null_blk
  rm -f guest.in guest.out
  print_title "Exit"
}
trap clean EXIT

function run_qemu() {
  mkdir -p "${root_dir}/tmp/domain-222-29ec19c9-d330-4949-b"
  mkfifo guest.out guest.in 2>/dev/null

  local serial=""
  local run_mode=""
  local console_tty=""
  local cpu_bind=""

  if [ $debug -ne 0 ]; then
    serial="mon:stdio"
  else
    serial="pipe:guest"
    run_mode="&"
  fi

  if [ "${arch}" = "aarch64" ]; then
      console_tty="ttyAMA0"
  else
      console_tty="ttyS0"
  fi

  if [ -n "$qemu_cpu" ]; then
    cpu_bind="--physcpubind=$qemu_cpu"
  fi

  eval cgexec -g cpuset:/ numactl --cpunodebind=$numa --membind=$numa $cpu_bind "${qemu_bin}" \
    -kernel "${kernel}" \
    -initrd "${initrd}" \
    -append '"rapido.vm_num=1 rd.systemd.unit=dracut-cmdline.service console=${console_tty} scsi_mod.use_blk_mq=y dm_mod.use_blk_mq=y transparent_hugepage=never systemd.unified_cgroup_hierarchy=0 noibrs noibpb nopti nospectre_v2 nospectre_v1 l1tf=off nospec_store_bypass_disable no_stf_barrier mds=off tsx=on tsx_async_abort=off mitigations=off"' \
    -uuid 1869b108-42b3-42a7-852e-70261d73f6a9 \
    -name guest=1869b108-42b3-42a7-852e-70261d73f6a9 \
    -smp $cpu \
    -m size=${mem}M,maxmem=32G,slots=12 \
    -device pci-bridge,chassis_nr=1,id=pci.0 \
    -device pci-bridge,chassis_nr=1,id=pci.1 \
    -device virtio-scsi-pci,id=scsi0,bus=pci.0,addr=0x10 \
    -device virtio-balloon \
    -device virtio-serial-pci,id=virtio-serial0,max_ports=16 \
    $extra \
    $disks \
    -chardev socket,id=charmonitor,path="${root_dir}/tmp/domain-222-29ec19c9-d330-4949-b/monitor.sock",server=on,wait=off \
    -serial ${serial} \
    -nographic \
    -mon chardev=charmonitor,id=monitor,mode=control ${run_mode}
    #-fsdev local,security_model=mapped,id=fsdev-fs0,path=$(pwd) -device virtio-9p-pci,id=fs0,fsdev=fsdev-fs0,mount_tag=fs0 \

  if [ $debug -eq 0 ]; then
    qemu_pid=$!
    if [ "$enable_perf" -ne 0 ]; then
      sleep 1 # wait for perf to record correctly on some platform such as Hygon
      perf kvm -o "${root_dir}/tmp/perf_kvm.data.guest" stat record -p ${qemu_pid} &
      perf_pid=$!
    fi
  fi
}

function generate_script() {
  cp "${root_dir}/fio_perf.sh" "${root_dir}/tmp/fio_perf.sh"

  echo "runtime=${runtime}" >> "${root_dir}/tmp/fio_perf.sh"
  for mode in ${bs_rw[@]}; do
    IFS='-' read -r bs rw <<<"$mode"
    for job in ${jobs[@]}; do
      for depth in ${iodepth[@]}; do
        echo "run_fio ${rw} ${depth} ${bs} \$1 ${job}" >> "${root_dir}/tmp/fio_perf.sh"
      done
    done
  done
  echo "" >> "${root_dir}/tmp/fio_perf.sh"

  run_cmd_in_qemu "cat << '"EOF"' >fio_perf.sh\n$(cat ${root_dir}/tmp/fio_perf.sh)\nEOF"
  run_cmd_in_qemu "chmod +x fio_perf.sh"
}

function expect() {
  local length="${#1}"
  local i=0
  while true; do
    IFS= read -r -n 1 c <guest.out
    if [ "${1:${i}:1}" = "${c}" ]; then
      i="$((i + 1))"
      if [ "${length}" -eq "${i}" ]; then
        break
      fi
    else
      i=0
    fi
  done
}

function run_cmd_in_qemu() {
  expect "${qemu_prompt}" # means last command finished
  echo -e "${1}" >guest.in
}

function run_test_in_qemu() {
  name=$1
  device=$2
  result_file=${root_dir}/test-results/$name.txt.$(date +%Y%m%d-%H%M%S)

  run_cmd_in_qemu "./fio_perf.sh $device && echo END"
  print_title "Start running test of [$name]"
  head -n 1 guest.out >/dev/null # discard the first line which is just our command

  while true; do
    tmp=$(head -n 1 guest.out)
    if [ "${tmp:0:3}" == "END" ]; then
      break
    elif [ "${tmp:0:1}" != "[" ]; then # discard kernel output
      echo "$tmp" | tee -a "$result_file"
    fi
  done

  echo "" >>"$result_file"
  run_cmd_in_qemu "wc -l /tmp/fio-cmds.txt | awk '{print \$1}'"
  cmds_lines=$(head -n 2 guest.out | tail -n 1)
  cmds_lines=${cmds_lines//$'\r'} # replace \r at the end to avoid syntax error
  run_cmd_in_qemu "cat /tmp/fio-cmds.txt"
  head -n $((cmds_lines + 1)) guest.out | tail -n $cmds_lines >>"$result_file"
  print_title "Test of [$name] is end"
  echo "Test result stored in $result_file"
}

function run_tests() {
  print_title "Booting KVM"

  generate_script

  for ((i = 0; i < ${#scsi_test_disks[@]}; i++)); do
    # convert to /dev/sd[a-z]
    disk="/dev/sd$(printf "\x$(printf %x $((97 + i)))")"
    if [ "$enable_warmup" -ne 0 ]; then
        run_cmd_in_qemu "fio --bs=256k --iodepth=128 --numjobs=1 --rw=write --filename=${disk} --ioengine=libaio --direct=1 --name=warm"
        print_title "Warmup ${scsi_test_disks[$i]}"
    fi
    run_test_in_qemu "${scsi_test_disks[$i]}" "$disk"
  done

  for ((i = 0; i < ${#blk_test_disks[@]}; i++)); do
    # convert to /dev/vd[a-z]
    disk="/dev/vd$(printf "\x$(printf %x $((97 + i)))")"
    if [ "$enable_warmup" -ne 0 ]; then
        run_cmd_in_qemu "fio --bs=256k --iodepth=128 --numjobs=1 --rw=write --filename=${disk} --ioengine=libaio --direct=1 --name=warm"
        print_title "Warmup ${blk_test_disks[$i]}"
    fi
    run_test_in_qemu "${blk_test_disks[$i]}" "$disk"
  done

  run_cmd_in_qemu "exit"

  if [ "$enable_perf" -ne 0 ]; then
    print_title "Perf kvm stat"
    perf_result_file=${root_dir}/test-results/perf_kvm_stat.txt.$(date +%Y%m%d-%H%M%S)
    kill -2 $perf_pid # perf will record events until it is terminated with SIGINT
    wait $perf_pid
    perf kvm -i "${root_dir}/tmp/perf_kvm.data.guest" stat report 2>&1 | tee ${perf_result_file}
    echo "Perf kvm stat result stored in ${perf_result_file}"
  fi
}

function main() {
  env_check

  print_kv "ARGS" "$*"
  parse_args "$@"

  run_qemu

  if [ $debug -eq 0 ]; then
    run_tests
  fi
}

function usage() {
  underline="\033[4m"
  reset="\033[0m"

  echo -e "Usage: $(basename $0) [TYPE=OPTIONS[ ...]]\n"
  echo -e "Default: $(basename $0) local-blk=/dev/nullb0\n"
  echo -e "Example: $(basename $0) local-blk=/dev/nullb0 zbs-iscsi-scsi=test/1 spdk-iscsi-blk=/dev/nullb1 spdk-vhost-scsi=/dev/nullb2 zbs-vhost-blk=test/2\n"
  echo -e "TYPE and OPTIONS:"
  echo -e "    local-blk=${underline}path${reset}[,...]"
  echo -e "        ${underline}Path${reset} is the path of local blk-device wanted to use(support to use null_blk with \"/dev/nullb0\")."
  echo -e "    zbs-iscsi-{scsi|blk}=${underline}target${reset}/${underline}lun${reset}[,...]"
  echo -e "        This will use zbs-iscsi as the backend. QEMU will use \"scsi-hd\" or \"virtio-blk-pci\" to mount device."
  echo -e "        ${underline}Target${reset} is the target name in zbs and ${underline}lun${reset} is the lun id."
  echo -e "    spdk-iscsi-{scsi|blk}=${underline}path${reset}[,...]"
  echo -e "        This will use spdk_tgt to create SPDK iscsi target. QEMU will use \"scsi-hd\" or \"virtio-blk-pci\" to mount device."
  echo -e "        ${underline}Path${reset} is the path of local blk-device wanted to use as the backend of bdev(support to use null_blk with \"/dev/nullb0\")."
  echo -e "    spdk-vhost-{scsi|blk}=${underline}path${reset}[,...]"
  echo -e "        This will use spdk_tgt to create vhost-scsi or vhost-blk. QEMU will use \"vhost-user-scsi-pci\" or \"vhost-user-blk-pci\" to mount device."
  echo -e "        ${underline}Path${reset} is the path of local blk-device wanted to use as the backend of bdev(support to use null_blk with \"/dev/nullb0\")."
  echo -e "    zbs-vhost-{scsi|blk}=${underline}target${reset}/${underline}lun${reset}[,...]"
  echo -e "        This will use zbs-procurator to create bdev and controller. QEMU will use \"vhost-user-scsi-pci\" or \"vhost-user-blk-pci\" to mount device."
  echo -e "        ${underline}Target${reset} is the target name in zbs and ${underline}lun${reset} is the lun id."
  echo -e "    modes=${underline}bs${reset}[+${underline}bs${reset}]/${underline}rw${reset}[+${underline}rw${reset}] [,...]"
  echo -e "        This will choose the test to run with fio, ${underline}bs${reset} is the block size and ${underline}rw${reset} is the IO type."
  echo -e "        For each pair split by '/', every ${underline}bs${reset} will match every ${underline}rw${reset}(For example, modes=4k+256k/randread+write will run 4k-randread 4k-write 256k-randread 256k-write)."
  echo -e "        The default value is 4k+256k/randread+randwrite."
  echo -e "    iodepth=${underline}depth${reset}[,...]"
  echo -e "        ${underline}Depth${reset} is the iodepth in fio test(1,128 by default)."
  echo -e "    jobs=${underline}job${reset}[,...]"
  echo -e "        ${underline}Job${reset} is the numjobs in fio test(1,2 by default)."
  echo -e "    runtime=${underline}time${reset}"
  echo -e "        ${underline}Time${reset} is the runtime in fio test(10 by default)."
  echo -e "The following environment variables can be specified."
  echo -e "QEMU              QEMU executable binary path."
  echo -e "KERNEL            QEMU kernel image($(uname -m)/guest/bzImage by default)."
  echo -e "INITRD            QEMU initial ram disk file($(uname -m)/guest/initrd by default)."
  echo -e "CPU               QEMU CPU numbers(4 by default)."
  echo -e "MEM               QEMU RAM size in MB(2048 by default)."
  echo -e "QEMU_CPU          List of CPUs bound by QEMU(Support N,N,N or N-N or N,N-N or N-N,N-N. All CPUs on the specified node of NUMA by default)."
  echo -e "QEMU_PROMPT       Shell prompt inside QEMU for checking whether a command is finished(rapido1:/root/blktests# by default)."
  echo -e "PERF              Enable perf kvm stat(0 by default)."
  echo -e "RUN_SPDK          Run a spdk_tgt process(1 by default)."
  echo -e "SPDK_SOCK         SPDK RPC listen address(${root_dir}/tmp/spdk.sock by default)."
  echo -e "SPDK_VHOST_SOCK   SPDK UNIX domain sockets dir used by vhost(${root_dir}/tmp by default)."
  echo -e "RECONNECT         The timeout for reconnecting vhost sockets(1 by default)."
  echo -e "SPDK_TGT_CPUMASK  SPDK application CPU mask(first two cpu of selected NUMA node by default)."
  echo -e "SPDK_SCSI_CPUMASK SPDK vhost-scsi controller CPU mask(empty by default)."
  echo -e "SPDK_BLK_CPUMASK  SPDK vhost-blk controller CPU mask(empty default)."
  echo -e "IOTHREAD          Enable iothread when create virtio-blk-pci device(1 by default)."
  echo -e "VHOST_QUEUES  QEMU vhost-user-blk/scsi-pci num-queues(${vhost_queues} by default)."
  echo -e "PORTAL            QEMU iSCSI file.portal(127.0.0.1 by default)."
  echo -e "NUMA              (0 by default)."
  echo -e "WARMUP            Warmup the device before run test(0 by default)."
  echo -e "DEBUG             Do not run tests automatically but run QEMU in the foreground if DEBUG is not equal to 0(0 by default)."
  echo -e "SIZE_HP           Set the total hugepages size, unit GiB (0 by default)."
}

case "$1" in
"-h" | "--help")
  trap - EXIT
  usage
  ;;
*)
  main "${@:-"local-blk=/dev/nullb0"}"
  ;;
esac
