#!/usr/bin/env bash
set -Eeuo pipefail

OUTDIR="/export-files"

read -rp "Enter VM ID to export: " VMID

if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: VM ID must be a number."
    exit 1
fi

if ! qm status "$VMID" >/dev/null 2>&1; then
    echo "ERROR: VM $VMID does not exist on this node."
    exit 1
fi

CONFIG="$(qm config "$VMID")"
VMNAME="$(awk -F': ' '/^name:/{print $2; exit}' <<< "$CONFIG")"
VMNAME="${VMNAME:-vm-$VMID}"
SAFE_NAME="$(printf '%s' "$VMNAME" | tr ' /' '__' | tr -cd '[:alnum:]_.-')"
SAFE_NAME="${SAFE_NAME:-vm-$VMID}"

mkdir -p "$OUTDIR"
VMDK="$OUTDIR/${SAFE_NAME}.vmdk"
OVF="$OUTDIR/${SAFE_NAME}.ovf"

DISK_LINES="$(grep -E '^(scsi|sata|virtio|ide)[0-9]+:' <<< "$CONFIG" || true)"
DISK_COUNT="$(grep -c . <<< "$DISK_LINES" || true)"

if [[ "$DISK_COUNT" -eq 0 ]]; then
    echo "ERROR: No scsi/sata/virtio/ide disk found."
    exit 1
fi

if [[ "$DISK_COUNT" -gt 1 ]]; then
    echo "WARNING: VM has $DISK_COUNT disks; this script exports ONLY the first one."
fi

DISK_LINE="$(head -n1 <<< "$DISK_LINES")"
DISK_SPEC="${DISK_LINE#*: }"
STORAGE="${DISK_SPEC%%:*}"
REST="${DISK_SPEC#*:}"
VOLUME="${REST%%,*}"
DISK_PATH="$(pvesm path "$STORAGE:$VOLUME")"

if [[ ! -e "$DISK_PATH" ]]; then
    echo "ERROR: Cannot access disk: $DISK_PATH"
    exit 1
fi

MEMORY_MIB="$(awk '/^memory:/{print $2; exit}' <<< "$CONFIG")"
CORES="$(awk '/^cores:/{print $2; exit}' <<< "$CONFIG")"
MEMORY_MIB="${MEMORY_MIB:-512}"
CORES="${CORES:-1}"

DISK_BYTES="$(qemu-img info --output=json "$DISK_PATH" | python3 -c '
import json,sys
print(json.load(sys.stdin)["virtual-size"])
')"

echo
echo "VM: $VMID ($VMNAME)"
echo "Disk: $DISK_PATH"
echo "RAM: ${MEMORY_MIB} MiB"
echo "CPU: $CORES"
echo "Output: $OUTDIR"
echo

if [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; then
    echo "Shutting down VM $VMID..."
    qm shutdown "$VMID"
    echo "Waiting up to 120 seconds..."
    stopped=0
    for _ in {1..60}; do
        sleep 2
        if [[ "$(qm status "$VMID" | awk '{print $2}')" == "stopped" ]]; then
            stopped=1
            break
        fi
    done
    if [[ "$stopped" -ne 1 ]]; then
        echo "ERROR: VM did not shut down within 120 seconds."
        echo "The VM was NOT force-stopped."
        exit 1
    fi
else
    echo "VM is already stopped."
fi

rm -f "$VMDK" "$OVF"

echo "Converting disk to streamOptimized VMDK..."
qemu-img convert -p -O vmdk -o subformat=streamOptimized "$DISK_PATH" "$VMDK"

VMDK_SIZE="$(stat -c%s "$VMDK")"
MEMORY_BYTES=$((MEMORY_MIB * 1024 * 1024))
FILE_NAME="$(basename "$VMDK")"

python3 - "$OVF" "$VMDK_SIZE" "$DISK_BYTES" "$SAFE_NAME" "$VMID" "$MEMORY_BYTES" "$CORES" "$FILE_NAME" <<'PY'
import html, sys

ovf_file, vmdk_size, disk_bytes, name, vmid, memory_bytes, cores, file_name = sys.argv[1:]
vmdk_size = int(vmdk_size)
disk_bytes = int(disk_bytes)
memory_bytes = int(memory_bytes)
cores = int(cores)
name = html.escape(name)

xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<ovf:Envelope
 xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
 xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
 xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">

  <ovf:References>
    <ovf:File ovf:id="file1" ovf:href="{file_name}" ovf:size="{vmdk_size}"/>
  </ovf:References>

  <ovf:DiskSection>
    <ovf:Info>Virtual disk information</ovf:Info>
    <ovf:Disk ovf:diskId="vmdisk1"
      ovf:fileRef="file1"
      ovf:capacity="{disk_bytes}"
      ovf:capacityAllocationUnits="byte"
      ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </ovf:DiskSection>

  <ovf:NetworkSection>
    <ovf:Info>Network information</ovf:Info>
    <ovf:Network ovf:name="VM Network">
      <ovf:Description>VM Network</ovf:Description>
    </ovf:Network>
  </ovf:NetworkSection>

  <ovf:VirtualSystem ovf:id="vm-{vmid}">
    <ovf:Info>Virtual machine exported from Proxmox VE</ovf:Info>
    <ovf:Name>{name}</ovf:Name>

    <ovf:OperatingSystemSection ovf:id="36">
      <ovf:Info>Linux 64-bit</ovf:Info>
      <ovf:Description>Linux 64-bit</ovf:Description>
    </ovf:OperatingSystemSection>

    <ovf:VirtualHardwareSection>
      <ovf:Info>Virtual hardware</ovf:Info>
      <ovf:System>
        <vssd:ElementName>Virtual Machine</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemType>vmx-07</vssd:VirtualSystemType>
      </ovf:System>

      <ovf:Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:ElementName>{cores} virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>{cores}</rasd:VirtualQuantity>
      </ovf:Item>

      <ovf:Item>
        <rasd:AllocationUnits>byte</rasd:AllocationUnits>
        <rasd:ElementName>Memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>{memory_bytes}</rasd:VirtualQuantity>
      </ovf:Item>

      <ovf:Item>
        <rasd:ElementName>Hard Disk 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceType>17</rasd:ResourceType>
      </ovf:Item>

      <ovf:Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>VM Network</rasd:Connection>
        <rasd:ElementName>Network Adapter 1</rasd:ElementName>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:ResourceType>10</rasd:ResourceType>
      </ovf:Item>
    </ovf:VirtualHardwareSection>
  </ovf:VirtualSystem>
</ovf:Envelope>
"""

with open(ovf_file, "w", encoding="utf-8") as f:
    f.write(xml)
PY

echo
echo "=========================================="
echo " EXPORT COMPLETE"
echo "=========================================="
echo
echo "OVF:  $OVF"
echo "VMDK: $VMDK"
echo
ls -lh "$OVF" "$VMDK"
echo
echo "VM $VMID is powered OFF."
