# Proxmox VM → OVF/VMDK Exporter

Export a Proxmox VE VM to a matching **OVF + streamOptimized VMDK** pair.

## Features

- Prompts for the Proxmox VM ID
- Verifies that the VM exists
- Detects the first `scsi`, `sata`, `virtio`, or `ide` disk
- Reads the VM's configured CPU and RAM
- Gracefully shuts down a running VM
- Converts the disk with `qemu-img` to `streamOptimized` VMDK
- Generates a matching OVF descriptor
- Saves output under `/export-files`
- Never force-stops a VM if graceful shutdown fails

## Requirements

Run on a **Proxmox VE node as root**.

Required commands:

- `qm`
- `pvesm`
- `qemu-img`
- `python3`

## Usage

```bash
chmod +x export-ovf.sh
./export-ovf.sh
```

Example:

```text
Enter VM ID to export: 100
```

Output:

```text
/export-files/migrate-test.ovf
/export-files/migrate-test.vmdk
```

Upload both files to your destination system's OVF/VMDK importer. Leave the MF/manifest field empty unless the destination explicitly requires one.

## Important limitations

### One disk

The current version exports **only the first attached virtual disk**. If a VM has multiple disks, the script prints a warning.

### Network

The OVF contains a generic `VM Network` connection. Proxmox-specific bridge, firewall, and MAC configuration are not reproduced exactly.

### Shutdown

A running VM is shut down with `qm shutdown`. The script waits up to 120 seconds. If it does not stop, the script exits without forcefully stopping it.

After a successful export, the VM remains powered off. Start it again with:

```bash
qm start <VMID>
```

## Why streamOptimized?

The VMDK is created using:

```bash
qemu-img convert -O vmdk -o subformat=streamOptimized
```

This format is intended for OVF-based import workflows.

## Not a backup tool

This project is for **VM portability/export**, not for replacing Proxmox Backup Server or normal Proxmox backups.

## License

MIT
