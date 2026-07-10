# QEMU Emulator and Virtualizer Developer Guide

> **Document ID:** `qemu-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Context7 `/websites/qemu-project_gitlab_io_qemu` and official QEMU documentation

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. What QEMU is

QEMU provides full-system emulation, hardware-assisted virtualization, and user-mode CPU emulation. It can model complete machines or run foreign-architecture user programs.

Key modes:

- **System emulation**: CPU, memory, devices, firmware, storage, and networking.
- **Hardware-assisted virtualization**: guest executes using an accelerator when host and guest architectures permit it.
- **User-mode emulation**: runs a foreign-architecture process on another host OS, primarily on Unix-like hosts.

## 2. Relationship to Android Emulator

Android Emulator uses a QEMU-derived engine with Android-specific device models, graphics, sensors, snapshots, and management layers. Treat `emulator.exe` as the supported Android interface. Do not assume every generic QEMU flag is accepted by Android Emulator.

Use QEMU documentation to understand virtualization fundamentals; use Android Emulator documentation for AVD operation.

## 3. Core command model

A generic virtual machine command specifies:

```text
qemu-system-ARCH
  -machine MACHINE
  -cpu CPU
  -m MEMORY
  -smp VCPUS
  -accel ACCELERATOR
  -drive ...
  -netdev ...
  -device ...
  -display ...
```

Example conceptually:

```powershell
qemu-system-x86_64 `
  -machine q35 `
  -m 4096 `
  -smp 4 `
  -accel whpx `
  -drive file=vm.qcow2,if=virtio,format=qcow2 `
  -nic user,model=virtio-net-pci
```

Exact device availability depends on the build.

## 4. Accelerators

Common accelerator families include:

- KVM on Linux;
- HVF on macOS;
- WHPX on Windows;
- TCG software translation on supported hosts.

Check installed support:

```powershell
qemu-system-x86_64 -accel help
```

Hardware acceleration is faster but has host/guest architecture and platform constraints. TCG is more portable but slower.

## 5. Machine and CPU models

`-machine help` and `-cpu help` enumerate supported definitions:

```powershell
qemu-system-x86_64 -machine help
qemu-system-x86_64 -cpu help
```

For migration and long-lived VM images, avoid silently changing CPU exposure. Pin a compatible CPU model and machine version.

## 6. Storage

Common image formats:

- raw — simple and predictable, can be sparse;
- qcow2 — snapshots, copy-on-write, compression, and backing files;
- platform-specific formats where supported.

Create and inspect:

```powershell
qemu-img create -f qcow2 vm.qcow2 64G
qemu-img info vm.qcow2
qemu-img check vm.qcow2
```

Convert:

```powershell
qemu-img convert -p -f raw -O qcow2 disk.raw disk.qcow2
```

Specify formats explicitly. Format probing on untrusted images increases risk.

## 7. Networking

### User-mode networking

Easy setup, NAT-like behavior, limited inbound access unless ports are forwarded.

```powershell
-netdev user,id=n1,hostfwd=tcp::2222-:22 `
-device virtio-net-pci,netdev=n1
```

### TAP or bridged networking

Provides deeper network integration but requires host configuration and elevated privileges. Apply firewall rules and avoid bridging untrusted guests directly to sensitive networks.

## 8. Display and headless operation

Options vary by platform and build. Common approaches include SDL, GTK, VNC, SPICE, curses, or no graphical display.

```powershell
-display none
-nographic
```

`-nographic` also changes serial/monitor behavior. Understand the console routing before using it in automation.

## 9. Monitor and QMP

The human monitor supports interactive management. QMP is the JSON-based machine protocol intended for programmatic control.

Typical QMP lifecycle:

1. connect to socket;
2. receive greeting;
3. negotiate capabilities;
4. send JSON commands with IDs;
5. correlate responses and asynchronous events.

Prefer QMP over scraping human-monitor output.

## 10. Snapshots

Snapshots can exist inside qcow2 or be managed externally. They are useful for testing but can create complex dependency chains. Document:

- base image checksum;
- backing-file path;
- snapshot name;
- machine and QEMU version;
- whether the guest was quiesced.

Never move a qcow2 overlay without its backing file unless it has been flattened.

## 11. Firmware and boot

QEMU can boot BIOS or UEFI firmware. UEFI deployments often use separate immutable code and writable variable-store files. Preserve the variable store per VM and do not modify the shared firmware code image.

## 12. Devices

Prefer paravirtualized devices such as virtio when the guest supports them. Device choice affects drivers, performance, and migration compatibility.

Inspect available devices:

```powershell
qemu-system-x86_64 -device help
```

## 13. Debugging

Useful facilities include:

- serial console;
- monitor/QMP events;
- guest-agent integration;
- logging with selected trace categories;
- GDB stub for low-level debugging;
- `qemu-img check` for image integrity.

Do not enable verbose device tracing indefinitely in production; logs can be extremely large and may contain sensitive guest data.

## 14. Security

- Run guests as an unprivileged account.
- Use process sandboxing options supported by the build.
- Treat disk images and device inputs as untrusted.
- Disable unnecessary devices and network listeners.
- Bind VNC, QMP, and monitor sockets locally or protect them with strong controls.
- Keep QEMU patched; emulated device parsers are a significant attack surface.
- Prefer explicit image formats and read-only base images.

## 15. Troubleshooting

### Accelerator unavailable

Check Windows optional features, firmware virtualization, host policy, and `-accel help`. Fall back to TCG only when performance is acceptable.

### Guest cannot boot

Verify firmware, machine type, boot order, disk interface, image format, and guest architecture.

### Disk image appears corrupt

Stop the VM cleanly and run `qemu-img check`. Work on a copy when recovery is required.

### Port forwarding fails

Check host port conflicts, guest service binding, Windows Firewall, and the `hostfwd` syntax.

### Android Emulator mismatch

Use `emulator -help` rather than generic QEMU flags. Android's emulator wrapper intentionally exposes a different contract.
