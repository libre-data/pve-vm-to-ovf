# Proxmox VM → OVF/VMDK Exporter

Simple Bash script to export a Proxmox VE VM as **OVF + streamOptimized VMDK** files.

## Quick start

Run directly on a Proxmox node as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/libre-data/pve-vm-to-ovf/main/export-ovf.sh)
```

Enter the VM ID when prompted.

Or pass it directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/libre-data/pve-vm-to-ovf/main/export-ovf.sh) 100
```

## What it does

- Gracefully shuts down the VM
- Exports **all** `scsi`, `sata`, `virtio`, and `ide` disks
- Converts each disk to `streamOptimized` VMDK
- Creates one matching OVF containing all disks
- Preserves configured CPU and RAM
- Saves everything to `/export-files`
- Leaves the VM powered off
- Never force-stops a VM

## Example

A VM with two disks produces:

```text
/export-files/migrate-test.ovf
/export-files/migrate-test-scsi0.vmdk
/export-files/migrate-test-scsi1.vmdk
```

Upload the **OVF and all VMDKs from the same export** to your destination's OVF importer.

## Requirements

- Proxmox VE node
- Root access
- `qm`
- `pvesm`
- `qemu-img`
- `python3`

## Notes

The export focuses on portability. Proxmox-specific network settings such as bridges, firewall rules, and VLAN configuration are not reproduced exactly.

The script is **not a backup tool**. Keep normal Proxmox backups for recovery.

## License

MIT
