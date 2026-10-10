#!/bin/bash
#
# Copyright (c) 2026 Kata Containers Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Cold plug an emulated PCI device into a rootless Cloud Hypervisor sandbox
# without real VFIO hardware. The CI runner boots an Ubuntu VM (L2) whose QEMU
# emulates an Intel IOMMU and a QEMU "edu" PCI device. guest.sh then binds that
# device to vfio-pci inside L2 and runs a Kata pod (L3) that receives it.
#
# Usage: host.sh <containerd-shim-kata-v2> <runtime-rs clh config> <work dir>

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
readonly shim="$1"
readonly clh_config="$2"
readonly work="$3"

readonly kata_version="4.2.0"
readonly kata_tarball_url="https://github.com/kata-containers/kata-containers/releases/download/${kata_version}/kata-static-${kata_version}-amd64.tar.zst"
readonly ubuntu_base="https://cloud-images.ubuntu.com/releases/noble/release"
readonly ssh_port=2222

mkdir -p "${work}/dl" "${work}/share" "${work}/out"
readonly ssh_key="${work}/id_ed25519"
ssh_opts=(-i "${ssh_key}" -p "${ssh_port}" -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)

guest_ssh() {
	# shellcheck disable=SC2029 # the command is meant to run in L2
	ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 "$@"
}

collect() {
	guest_ssh "sudo tar -C /var/log/probe -cz ." > "${work}/out/guest-logs.tgz" || true
	if sudo test -f "${work}/qemu.pid"; then
		sudo kill "$(sudo cat "${work}/qemu.pid")" || true
	fi
	# QEMU runs as root, so its serial log is root-only until opened up here.
	sudo chmod -R a+rX "${work}/out"
}

echo "::group::Stage A: runner facts"
uname -a
grep -m1 'model name' /proc/cpuinfo
nproc
free -g
ls -l /dev/kvm
cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null || true
echo "::endgroup::"

echo "::group::Download Ubuntu cloud image, Kata ${kata_version} guest assets, Cloud Hypervisor"
clh_version="$(yq '.assets.hypervisor.cloud_hypervisor.version' "${repo_root}/versions.yaml")"
curl -fsSL -o "${work}/dl/ubuntu.img" "${ubuntu_base}/ubuntu-24.04-server-cloudimg-amd64.img"
curl -fsSL -o "${work}/dl/vmlinuz" "${ubuntu_base}/unpacked/ubuntu-24.04-server-cloudimg-amd64-vmlinuz-generic"
curl -fsSL -o "${work}/dl/initrd" "${ubuntu_base}/unpacked/ubuntu-24.04-server-cloudimg-amd64-initrd-generic"
curl -fsSL -o "${work}/share/cloud-hypervisor" \
	"https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/${clh_version}/cloud-hypervisor-static"
curl -fsSL -o "${work}/dl/kata.tar.zst" "${kata_tarball_url}"

# vmlinux.container and kata-containers.img are symlinks; read their targets
# first so only the default kernel and image are extracted.
share_dir="./opt/kata/share/kata-containers"
listing="$(tar --zstd -tvf "${work}/dl/kata.tar.zst" "${share_dir}/vmlinux.container" "${share_dir}/kata-containers.img")"
kernel_name="$(awk '/vmlinux.container/ {print $NF}' <<<"${listing}")"
image_name="$(awk '/kata-containers.img/ {print $NF}' <<<"${listing}")"
tar --zstd -xf "${work}/dl/kata.tar.zst" -C "${work}/dl" \
	"${share_dir}/${kernel_name}" "${share_dir}/${image_name}" ./opt/kata/libexec/virtiofsd
mv "${work}/dl/${share_dir}/${kernel_name}" "${work}/share/vmlinux"
mv "${work}/dl/${share_dir}/${image_name}" "${work}/share/kata-containers.img"
mv "${work}/dl/opt/kata/libexec/virtiofsd" "${work}/share/virtiofsd"
rm -rf "${work}/dl/kata.tar.zst" "${work}/dl/opt"
cp "${shim}" "${work}/share/containerd-shim-kata-v2"
cp "${clh_config}" "${work}/share/configuration-clh-runtime-rs.toml"
cp "${script_dir}/guest.sh" "${work}/share/guest.sh"
chmod +x "${work}/share/cloud-hypervisor" "${work}/share/virtiofsd" "${work}/share/containerd-shim-kata-v2"
echo "kernel=${kernel_name} image=${image_name} clh=${clh_version}"
echo "::endgroup::"

echo "::group::Boot L2 with an emulated IOMMU and edu device"
qemu-system-x86_64 -device help | grep -w '"edu"'
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"
cat > "${work}/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "${ssh_key}.pub")
growpart:
  mode: auto
EOF
printf 'instance-id: l2\nlocal-hostname: l2\n' > "${work}/meta-data"
cloud-localds "${work}/seed.img" "${work}/user-data" "${work}/meta-data"
qemu-img create -q -f qcow2 -F qcow2 -b "${work}/dl/ubuntu.img" "${work}/l2.qcow2" 20G

# kernel-irqchip=split is what intremap=on needs; without interrupt remapping
# vfio-pci in L2 refuses the device.
sudo qemu-system-x86_64 \
	-name l2 -machine q35,accel=kvm,kernel-irqchip=split -cpu host \
	-smp "$(($(nproc) - 1))" -m 10G \
	-device intel-iommu,intremap=on \
	-kernel "${work}/dl/vmlinuz" -initrd "${work}/dl/initrd" \
	-append "root=LABEL=cloudimg-rootfs ro console=ttyS0 intel_iommu=on iommu=pt" \
	-drive "file=${work}/l2.qcow2,if=virtio" \
	-drive "file=${work}/seed.img,if=virtio,format=raw" \
	-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" -device virtio-net-pci,netdev=n0 \
	-virtfs "local,path=${work}/share,mount_tag=probe,security_model=none,readonly=on" \
	-device edu \
	-display none -serial "file:${work}/out/l2-serial.log" \
	-daemonize -pidfile "${work}/qemu.pid"
trap collect EXIT

for _ in $(seq 1 60); do
	guest_ssh true 2>/dev/null && break
	sleep 5
done
guest_ssh true
echo "::endgroup::"

guest_ssh "sudo mkdir -p /mnt/probe && sudo mount -t 9p -o trans=virtio,version=9p2000.L probe /mnt/probe && sudo bash /mnt/probe/guest.sh"
