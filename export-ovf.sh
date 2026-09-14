#!/usr/bin/env bash
set -Eeuo pipefail

OUTDIR="/export-files"

if [[ ! -t 0 && -r /dev/tty ]]; then
    exec </dev/tty
fi

if [[ $# -ge 1 ]]; then
    VMID="$1"
else
    read -r -p "Enter VM ID to export: " VMID
fi

if [[ -z "${VMID:-}" || ! "$VMID" =~ ^[0-9]+$ ]]; then
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
OVF="$OUTDIR/${SAFE_NAME}.ovf"

mapfile -t DISKS < <(grep -E '^(scsi|sata|virtio|ide)[0-9]+:' <<< "$CONFIG" | sort -V || true)
DISK_COUNT="${#DISKS[@]}"

if [[ "$DISK_COUNT" -eq 0 ]]; then
    echo "ERROR: No scsi/sata/virtio/ide disk found."
    exit 1
fi

MEMORY_MIB="$(awk '/^memory:/{print $2; exit}' <<< "$CONFIG")"
CORES="$(awk '/^cores:/{print $2; exit}' <<< "$CONFIG")"
MEMORY_MIB="${MEMORY_MIB:-512}"
CORES="${CORES:-1}"

# Collect disk metadata before shutdown.
DISK_KEYS=()
DISK_PATHS=()
DISK_BYTES=()
DISK_NAMES=()
VMDKS=()

for line in "${DISKS[@]}"; do
    KEY="${line%%:*}"
    DISK_SPEC="${line#*: }"
    STORAGE="${DISK_SPEC%%:*}"
    REST="${DISK_SPEC#*:}"
    VOLUME="${REST%%,*}"
    DISK_PATH="$(pvesm path "$STORAGE:$VOLUME")"

    if [[ ! -e "$DISK_PATH" ]]; then
        echo "ERROR: Cannot access disk $KEY: $DISK_PATH"
        exit 1
    fi

    BYTES="$(qemu-img info --output=json "$DISK_PATH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')"
    VMDK_NAME="${SAFE_NAME}-${KEY}.vmdk"

    DISK_KEYS+=("$KEY")
    DISK_PATHS+=("$DISK_PATH")
    DISK_BYTES+=("$BYTES")
    DISK_NAMES+=("$VMDK_NAME")
    VMDKS+=("$OUTDIR/$VMDK_NAME")
done

echo
echo "VM: $VMID ($VMNAME)"
echo "Disks: $DISK_COUNT"
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

rm -f "$OVF" "${VMDKS[@]}"

for i in "${!DISKS[@]}"; do
    echo "Converting ${DISK_KEYS[$i]} to ${DISK_NAMES[$i]}..."
    qemu-img convert -p -O vmdk -o subformat=streamOptimized "${DISK_PATHS[$i]}" "${VMDKS[$i]}"
done

# Build a compact metadata file for OVF generation.
META="$(mktemp)"
trap 'rm -f "$META"' EXIT
for i in "${!DISKS[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "${DISK_KEYS[$i]}" "${DISK_NAMES[$i]}" "${DISK_BYTES[$i]}" "$(stat -c%s "${VMDKS[$i]}")" >> "$META"
done

MEMORY_BYTES=$((MEMORY_MIB * 1024 * 1024))
python3 - "$OVF" "$SAFE_NAME" "$VMID" "$MEMORY_BYTES" "$CORES" "$META" <<'PY'
import html, sys

ovf_file, name, vmid, memory_bytes, cores, meta_file = sys.argv[1:]
memory_bytes = int(memory_bytes)
cores = int(cores)
name = html.escape(name)

rows = []
with open(meta_file, encoding="utf-8") as f:
    for line in f:
        key, filename, capacity, size = line.rstrip("\n").split("\t")
        rows.append((key, filename, int(capacity), int(size)))

refs = []
disks = []
items = []
for n, (key, filename, capacity, size) in enumerate(rows, 1):
    file_id = f"file{n}"
    disk_id = f"vmdisk{n}"
    refs.append(f'    <ovf:File ovf:id="{file_id}" ovf:href="{html.escape(filename)}" ovf:size="{size}"/>')
    disks.append(f'    <ovf:Disk ovf:diskId="{disk_id}" ovf:fileRef="{file_id}" ovf:capacity="{capacity}" ovf:capacityAllocationUnits="byte" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>')
    items.append(f'      <ovf:Item><rasd:ElementName>Hard Disk {n} ({html.escape(key)})</rasd:ElementName><rasd:HostResource>ovf:/disk/{disk_id}</rasd:HostResource><rasd:InstanceID>{n + 2}</rasd:InstanceID><rasd:ResourceType>17</rasd:ResourceType></ovf:Item>')

xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<ovf:Envelope xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <ovf:References>
{chr(10).join(refs)}
  </ovf:References>
  <ovf:DiskSection>
    <ovf:Info>Virtual disk information</ovf:Info>
{chr(10).join(disks)}
  </ovf:DiskSection>
  <ovf:NetworkSection>
    <ovf:Info>Network information</ovf:Info>
    <ovf:Network ovf:name="VM Network"><ovf:Description>VM Network</ovf:Description></ovf:Network>
  </ovf:NetworkSection>
  <ovf:VirtualSystem ovf:id="vm-{vmid}">
    <ovf:Info>Virtual machine exported from Proxmox VE</ovf:Info>
    <ovf:Name>{name}</ovf:Name>
    <ovf:OperatingSystemSection ovf:id="36"><ovf:Info>Linux 64-bit</ovf:Info><ovf:Description>Linux 64-bit</ovf:Description></ovf:OperatingSystemSection>
    <ovf:VirtualHardwareSection>
      <ovf:Info>Virtual hardware</ovf:Info>
      <ovf:System><vssd:ElementName>Virtual Machine</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemType>vmx-07</vssd:VirtualSystemType></ovf:System>
      <ovf:Item><rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits><rasd:ElementName>{cores} virtual CPU(s)</rasd:ElementName><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>{cores}</rasd:VirtualQuantity></ovf:Item>
      <ovf:Item><rasd:AllocationUnits>byte</rasd:AllocationUnits><rasd:ElementName>Memory</rasd:ElementName><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>{memory_bytes}</rasd:VirtualQuantity></ovf:Item>
{chr(10).join(items)}
      <ovf:Item><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:Connection>VM Network</rasd:Connection><rasd:ElementName>Network Adapter 1</rasd:ElementName><rasd:InstanceID>{len(rows) + 3}</rasd:InstanceID><rasd:ResourceType>10</rasd:ResourceType></ovf:Item>
    </ovf:VirtualHardwareSection>
  </ovf:VirtualSystem>
</ovf:Envelope>
'''

with open(ovf_file, "w", encoding="utf-8") as f:
    f.write(xml)
PY

echo
echo "=========================================="
echo " EXPORT COMPLETE"
echo "=========================================="
echo
echo "OVF: $OVF"
for vmdk in "${VMDKS[@]}"; do echo "VMDK: $vmdk"; done
echo
echo "VM $VMID is powered OFF."
