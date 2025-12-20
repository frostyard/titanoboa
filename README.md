# Titanoboa (Beta)

A [bootc](https://github.com/bootc-dev/bootc) live iso generator. You bring the live session & setup, we make the iso.

## Components

- LiveCD

## Building a Live ISO

```bash
just build ghcr.io/frostyard/snow:latest
just vm ./output.iso
```

### Builder Distribution Support

By default, Titanoboa uses Debian containers for building tools and dependencies. You can specify different builder distributions using the `TITANOBOA_BUILDER_DISTRO` environment variable:

- **debian** (default): Uses `docker.io/library/debian:trixie`
- **ubuntu**: Uses `docker.io/library/ubuntu:noble`

Examples:

```bash
# Use Ubuntu for building
TITANOBOA_BUILDER_DISTRO=ubuntu just build ghcr.io/your-org/your-image:latest

# Use Debian (default)
just build ghcr.io/your-org/your-image:latest
```

### Secure Boot Support

The ISO is built with Secure Boot support using Debian's signed shim and GRUB binaries:

- `shim-signed`: Microsoft-signed shim bootloader
- `grub-efi-amd64-signed`: Signed GRUB EFI binary

These signed binaries are copied from the rootfs container image into the ISO's EFI partition, ensuring compatibility with UEFI Secure Boot.
