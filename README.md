# Proxmox VM → OVF/VMDK Exporter

Simple Bash script to export a Proxmox VE VM as **OVF + streamOptimized VMDK** files for migration to another virtualization platform.

## Quick start

Run directly on a Proxmox node as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/libre-data/pve-vm-to-ovf/main/export-ovf.sh)
```

Enter the VM ID when prompted.

Or pass the VM ID directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/libre-data/pve-vm-to-ovf/main/export-ovf.sh) 100
```

## What it does

- Gracefully shuts down the VM if it is running
- Exports **all** `scsi`, `sata`, `virtio`, and `ide` disks
- Converts every disk to `streamOptimized` VMDK
- Creates one matching OVF referencing all exported disks
- Includes the configured CPU and RAM in the OVF
- Saves the export to `/export-files`
- Starts a temporary HTTP server on port `8080` for easy downloading
- Leaves the VM powered **off** after the export
- Never force-stops a VM
- Asks whether to delete the exported files after downloading

## Multiple disks

The script automatically detects all supported VM disks.

For example, a VM with three disks produces:

```text
/export-files/test.ovf
/export-files/test-scsi0.vmdk
/export-files/test-scsi1.vmdk
/export-files/test-scsi2.vmdk
```

The OVF is generated to match the exported VMDKs, so **upload the OVF and all VMDKs from the same export together**.

## Download the export

After the export, the script starts a temporary web server and displays a link such as:

```text
http://192.168.1.10:8080/
```

Open the link in a browser and download the `.ovf` and all `.vmdk` files.

When the download is complete, return to the Proxmox terminal and press **ENTER** to stop the server.

The script then asks:

```text
Do you want to delete the exported OVF and VMDK files?
Press ENTER to keep them.
Delete exports? [y/N]:
```

Press **ENTER** to keep the files. Enter `y` to delete them.

## Requirements

- Proxmox VE node
- Root access
- `qm`
- `pvesm`
- `qemu-img`
- `python3`

These commands are normally available on a standard Proxmox VE installation.

## Notes

- Port `8080` must be available on the Proxmox node.
- The HTTP server is temporary and runs only while the script is waiting for you to press ENTER.
- The export is intended for VM migration and portability, not as a replacement for Proxmox backups.
- Proxmox-specific network settings such as bridges, firewall rules, and VLAN configuration are not reproduced exactly. The OVF uses a generic `VM Network`.
- The VM remains powered off when the script finishes.

## License

MIT
