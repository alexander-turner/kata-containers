#!/bin/bash
#
# Copyright (c) 2026 Kata Containers Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Runs as root inside the L2 VM that host.sh boots. Binds the emulated edu
# device (1234:11e8) to vfio-pci, then checks that a rootless Cloud Hypervisor
# sandbox started through the runtime-rs shim receives it:
#   - plain Cloud Hypervisor can pass the device through at all (stage C);
#   - the container sees the device, the VMM runs as a non-root user that owns
#     the IOMMU group node, and its RLIMIT_MEMLOCK covers guest RAM (stage D);
#   - deleting the sandbox restores the node's owner (stage E);
#   - a second sandbox receives the device again (stage F);
#   - a sandbox without the device tells whether a leftover VMM user is VFIO's doing (stage G).

set -o errexit
set -o nounset
set -o pipefail

readonly src=/mnt/probe
readonly logs=/var/log/probe
readonly image=docker.io/library/busybox:latest
readonly runtime=io.containerd.kata.v2
mkdir -p "${logs}"

fail() {
	echo "PROBE FAILED: $*" >&2
	exit 1
}

save_logs() {
	journalctl -u containerd --no-pager > "${logs}/containerd.log" 2>&1 || true
	dmesg > "${logs}/l2-dmesg.log" 2>&1 || true
	cp -r /run/kata-containers/vfio-grants "${logs}/" 2>/dev/null || true
}
trap save_logs EXIT

echo "::group::Stage B: L2 facts and vfio-pci binding"
uname -r
ls -l /dev/kvm || fail "no /dev/kvm in L2: the runner does not offer nested virtualization two levels deep"
dmesg | grep -iE 'DMAR|IOMMU' | head -n 20 || true
[[ -n "$(ls /sys/kernel/iommu_groups)" ]] || fail "no IOMMU groups in L2"

bdf=""
for dev in /sys/bus/pci/devices/*; do
	if [[ "$(cat "${dev}/vendor")" == 0x1234 && "$(cat "${dev}/device")" == 0x11e8 ]]; then
		bdf="$(basename "${dev}")"
	fi
done
[[ -n "${bdf}" ]] || fail "edu device not found in L2"
group="$(basename "$(readlink "/sys/bus/pci/devices/${bdf}/iommu_group")")"
modprobe vfio-pci
echo vfio-pci > "/sys/bus/pci/devices/${bdf}/driver_override"
echo "${bdf}" > /sys/bus/pci/drivers_probe
readonly vfio_node="/dev/vfio/${group}"
[[ -c "${vfio_node}" ]] || fail "${vfio_node} missing after binding ${bdf} to vfio-pci"
orig_owner="$(stat -c '%u:%g %a' "${vfio_node}")"
ls -l /dev/vfio
echo "edu ${bdf} in IOMMU group ${group}"
echo "::endgroup::"

echo "::group::Install containerd, Kata assets and the shim under test"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q containerd
# enable_debug floods the journal; without this, journald drops the shim's teardown lines.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nRateLimitBurst=0\n' > /etc/systemd/journald.conf.d/probe.conf
systemctl restart systemd-journald
systemctl start containerd
install -D -m 0755 "${src}/cloud-hypervisor" /opt/kata/bin/cloud-hypervisor
install -D -m 0755 "${src}/virtiofsd" /opt/kata/libexec/virtiofsd
install -D -m 0644 "${src}/vmlinux" /opt/kata/share/kata-containers/vmlinux.container
install -D -m 0644 "${src}/kata-containers.img" /opt/kata/share/kata-containers/kata-containers.img
install -D -m 0755 "${src}/containerd-shim-kata-v2" /usr/local/bin/containerd-shim-kata-v2

readonly config=/etc/kata-containers/runtime-rs/configuration.toml
install -D -m 0644 "${src}/configuration-clh-runtime-rs.toml" "${config}"
sed -i \
	-e 's|^path = .*|path = "/opt/kata/bin/cloud-hypervisor"|' \
	-e 's|^kernel = .*|kernel = "/opt/kata/share/kata-containers/vmlinux.container"|' \
	-e 's|^image = .*|image = "/opt/kata/share/kata-containers/kata-containers.img"|' \
	-e 's|^virtio_fs_daemon = .*|virtio_fs_daemon = "/opt/kata/libexec/virtiofsd"|' \
	-e 's|^rootless = .*|rootless = true|' \
	-e 's|^enable_debug = .*|enable_debug = true|' \
	-e 's|^reconnect_timeout_ms = .*|reconnect_timeout_ms = 120000|' \
	-e 's|^create_container_timeout = .*|create_container_timeout = 600|' \
	-e '/^\[hypervisor.clh\]$/a cold_plug_vfio = "root-port"' \
	"${config}"
grep -nE '^(path|kernel|image|rootless|cold_plug_vfio|default_memory|shared_fs) =' "${config}"
guest_mem_mib="$(awk -F' *= *' '$1 == "default_memory" {print $2; exit}' "${config}")"
ctr image pull "${image}" > /dev/null
echo "::endgroup::"

echo "::group::Stage C: plain Cloud Hypervisor passes the device through"
# No root filesystem: the kernel enumerates PCI, then panics and stays halted.
timeout 180 /opt/kata/bin/cloud-hypervisor \
	--kernel /opt/kata/share/kata-containers/vmlinux.container \
	--cmdline "console=ttyS0 loglevel=8 panic=0" \
	--cpus boot=1 --memory size=512M --serial tty --console off \
	--device "path=/sys/bus/pci/devices/${bdf}/" > "${logs}/clh-plain.log" 2>&1 || true
grep -m1 '\[1234:11e8\]' "${logs}/clh-plain.log" ||
	fail "the L3 kernel did not enumerate the edu device; see clh-plain.log"
echo "::endgroup::"

# Prints what a deleted sandbox left on the host, for the leak check below.
leftovers() {
	local id="$1" uid="$2"
	echo "-- ${id}: VMM user ${uid}: $(getent passwd "${uid}" || echo deleted)"
	pgrep -a -f 'cloud-hypervisor|virtiofsd' || echo "-- no cloud-hypervisor or virtiofsd process"
	find /sys/fs/cgroup -type d \( -name "*${id}*" -o -name 'kata*' \) | while read -r cg; do
		echo "-- cgroup ${cg}: procs [$(tr '\n' ' ' < "${cg}/cgroup.procs")]"
	done
	ls -la "/run/kata/${id}" 2>/dev/null || echo "-- /run/kata/${id} removed"
}

# Starts a detached sandbox, with the device when one is given, and sets vmm_pid and vmm_uid.
start_sandbox() {
	local id="$1" device=("${@:2}")
	timeout 900 ctr run -d --runtime "${runtime}" "${device[@]}" "${image}" "${id}" sleep 3600
	vmm_pid="$(pgrep -f -n /opt/kata/bin/cloud-hypervisor)"
	vmm_uid="$(stat -c %u "/proc/${vmm_pid}")"
}

# Deletes a sandbox and reports whether its VMM user is gone within 30 s.
stop_sandbox() {
	local id="$1" uid="$2"
	ctr task kill -s SIGKILL "${id}"
	for _ in $(seq 1 60); do
		ctr task ls | awk 'NR > 1 {print $1}' | grep -qx "${id}" || break
		ctr task delete "${id}" 2>/dev/null || sleep 2
	done
	ctr container delete "${id}"
	for _ in $(seq 1 30); do
		getent passwd "${uid}" > /dev/null || return 0
		sleep 1
	done
	leftovers "${id}" "${uid}" | tee "${logs}/${id}-leftovers.txt"
	return 1
}

# shellcheck disable=SC2016 # expanded by the shell inside the container
pci_ids_cmd='for d in /sys/bus/pci/devices/*; do echo "$(cat $d/vendor):$(cat $d/device)"; done'

echo "::group::Stage D: the shim cold plugs the device into a rootless sandbox"
start_sandbox probe1 --device "${vfio_node}"
timeout 120 ctr task exec --exec-id ids probe1 sh -c "${pci_ids_cmd}" | tee "${logs}/probe1-pci.txt"
grep -qx '0x1234:0x11e8' "${logs}/probe1-pci.txt" || fail "the container does not see the edu device"

node_owner="$(stat -c '%u:%g %a' "${vfio_node}")"
memlock="$(awk '/^Max locked memory/ {print $4}' "/proc/${vmm_pid}/limits")"
echo "vmm pid=${vmm_pid} uid=${vmm_uid}; ${vfio_node} ${node_owner}; memlock soft=${memlock} bytes; guest=${guest_mem_mib} MiB"
ls -l /run/kata-containers/vfio-grants/
[[ "${vmm_uid}" != 0 ]] || fail "the VMM runs as root; rootless mode is not in effect"
[[ "${node_owner%%:*}" == "${vmm_uid}" ]] || fail "${vfio_node} is not owned by the VMM user"
[[ "${memlock}" == unlimited ]] || ((memlock >= guest_mem_mib * 1024 * 1024)) ||
	fail "RLIMIT_MEMLOCK ${memlock} is below guest memory"
echo "::endgroup::"

echo "::group::Stage E: deleting the sandbox restores the node"
vfio_user_leaked=false
stop_sandbox probe1 "${vmm_uid}" || vfio_user_leaked=true
node_owner="$(stat -c '%u:%g %a' "${vfio_node}")"
echo "${vfio_node} ${node_owner}"
[[ "${node_owner}" == "${orig_owner}" ]] || fail "${vfio_node} was not restored to ${orig_owner}"
[[ -z "$(ls -A /run/kata-containers/vfio-grants/)" ]] || fail "a grant ledger was left behind"
echo "::endgroup::"

echo "::group::Stage F: a second sandbox receives the device again"
timeout 900 ctr run --rm --runtime "${runtime}" --device "${vfio_node}" "${image}" probe2 sh -c "${pci_ids_cmd}" |
	tee "${logs}/probe2-pci.txt"
grep -qx '0x1234:0x11e8' "${logs}/probe2-pci.txt" || fail "the second container does not see the edu device"
[[ "$(stat -c '%u:%g %a' "${vfio_node}")" == "${orig_owner}" ]] || fail "${vfio_node} not restored after the second sandbox"
echo "::endgroup::"

echo "::group::Stage G: control sandbox without a device"
start_sandbox probe3
plain_user_leaked=false
stop_sandbox probe3 "${vmm_uid}" || plain_user_leaked=true
echo "VMM user left behind: with VFIO ${vfio_user_leaked}, without ${plain_user_leaked}"
echo "::endgroup::"

if [[ "${vfio_user_leaked}" == true && "${plain_user_leaked}" == false ]]; then
	fail "only the VFIO sandbox left its VMM user behind; see probe1-leftovers.txt"
fi
if [[ "${vfio_user_leaked}" == true ]]; then
	echo "::warning::rootless CLH cleanup leaves the VMM user behind with or without VFIO; see probe1-leftovers.txt"
fi
echo "PROBE PASSED"
