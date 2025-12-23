set unstable := true
PODMAN := which("podman") || require("podman-remote")
workdir := env("TITANOBOA_WORKDIR", "work")
isoroot := env("TITANOBOA_ISO_ROOT", "work/iso-root")
rootfs := workdir/"rootfs"
default_image := "ghcr.io/frostyard/snow:latest"
extra_kargs := "snow-linux.live=1"
instance_name := env("TITANOBOA_INSTANCE_NAME", "titanoboa-live")
arch := arch()
### BUILDER CONFIGURATION ###
# Distribution to use for the builder container (for tools and dependencies)
# Supported values: debian, ubuntu
# Set via TITANOBOA_BUILDER_DISTRO environment variable (default: debian)
builder_distro := env("TITANOBOA_BUILDER_DISTRO", "debian")
##############################

### HOOKS SCRIPT PATHS ###
# Path to scripts used as hooks in between steps, used in 'hook-*' recipes.
# Must follow the naming convention HOOK_<recipe name without 'hook_' prefix>

# Hook used for custom operations done in the rootfs before it is squashed.
HOOK_post_rootfs := env("HOOK_post_rootfs", "")

# Hook used for custom operations done before the initramfs is generated.
HOOK_pre_initramfs := env("HOOK_pre_initramfs", "")
##########################

### UTILS ###
_ci_grouping := '''
if [[ -n "${CI:-}" ]]; then
    echo "::group::${BASH_SOURCE[0]##*/} step"
    trap 'echo ::endgroup::' EXIT
fi
'''
[private]
just := just_executable() + " -f " + source_file()

[private]
git_root := source_dir()

[private]
builder_image := if builder_distro == "debian" { "docker.io/library/debian:trixie" } else if builder_distro == "ubuntu" { "docker.io/library/ubuntu:noble" } else { error("Unsupported builder distribution: " + builder_distro + ". Supported: debian, ubuntu") }


[private]
chroot_function := '
function chroot(){
    local command="$1"
    shift
    local args="$*"
    ' + PODMAN + ' run --rm -it \
    --privileged \
    --security-opt label=type:unconfined_t \
    $args \
    --tmpfs /tmp:rw \
    --tmpfs /run:rw \
    --volume ' + git_root + ':/app \
    --rootfs ' + git_root/rootfs + ' \
    /usr/bin/bash -c "$command"
}'

[private]
builder_function := '
function builder(){
    local command="$1"
    shift
    local args="$*"
    ' + PODMAN + ' run --rm -it \
    --privileged \
    --security-opt label=disable \
    --volume ' + git_root + ':/app \
    ' + builder_image + ' \
    /usr/bin/bash -c "$command" $args
}'

[private]
compress_dependencies := '''
function compress_dependencies(){
    local MISSING=()
    local DEPS=(
        mksquashfs
        mkfs.erofs
    )
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep >/dev/null; then
            MISSING+=($dep)
        fi
    done
    echo "${#MISSING[@]}"
}
'''

[private]
iso_dependencies := '
function iso_dependencies(){
    local MISSING=()
    local PKGS=(
        dosfstools
        grub-common
        grub-efi-amd64-bin
        grub-efi-amd64-signed
        grub-pc-bin
        shim-signed
        xorriso
        mtools
    )
    if [[ "' + arch + '" == "aarch64" ]]; then
        PKGS+=(grub-efi-arm64-bin grub-efi-arm64-signed)
    fi
    if ! command -v dpkg >/dev/null; then
        echo "1"
        return
    fi
    for pkg in "${PKGS[@]}"; do
        if ! dpkg -s $pkg >/dev/null 2>&1; then
            MISSING+=($pkg)
        fi
    done
    echo "${#MISSING[@]}"
}'
#############

# Default
@default:
    {{ just }} --list

# Create Directories
init-work:
    @echo "{{ style('command') }}Creating Work Directories...{{ NORMAL }}" >&2
    mkdir -p {{ workdir }}
    mkdir -p {{ isoroot }}
    mkdir -p {{ rootfs }}

# Extract rootfs
rootfs image=default_image:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    # Pull and Extract Filesystem
    {{ PODMAN }} rmi {{ image }} 2>/dev/null || true
    {{ PODMAN }} pull {{ image }}
    ctr="$({{ PODMAN }} create --rm {{ image }} /usr/bin/bash)" && trap "{{ PODMAN }} rm $ctr" EXIT
    {{ PODMAN }} export $ctr | tar --xattrs-include='*' -p -xf - -C {{ rootfs }}

    # Make /var/tmp be a tmpfs by symlinking to /tmp,
    # in order to make bootc work at runtime.
    rm -rf {{ rootfs }}/var/tmp
    ln -sr {{ rootfs }}/tmp {{ rootfs }}/var/tmp

# Generate initramfs with live modules
initramfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -euo pipefail
    CMD='set -xeuo pipefail
    apt-get update
    apt-get install -y dracut-live
    KERNEL_VERSION=$(basename "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)")
    mkdir -p $(realpath /root)
    export DRACUT_NO_XATTR=1
    dracut --force --no-hostonly --reproducible --zstd --verbose --kver "$KERNEL_VERSION" --add "dmsquash-live dmsquash-live-autooverlay" /app/{{ workdir }}/initramfs.img |& grep -v -e "Operation not supported"'
    chroot "$CMD"

# Embed the container
rootfs-include-container container_image=default_image image=default_image:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -euo pipefail
    CMD="set -xeuo pipefail
    mkdir -p /var/lib/containers/storage"
    chroot "$CMD"

# Install Flatpaks into the live system
rootfs-include-flatpaks FLATPAKS_FILE="src/flatpaks.example.txt":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if FLATPAKS_FILE =~ '(^$|^(?i)\bnone\b$)' { 'exit 0' } else if path_exists(FLATPAKS_FILE) == 'false' { error('Flatpak file inaccessible: ' + FLATPAKS_FILE) } else { '' } }}
    {{ chroot_function }}
    CMD='set -xeuo pipefail
    mkdir -p /var/lib/flatpak

    # Get Flatpaks
    flatpak remote-add --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
    # grep -v "#.*" /flatpak-list/$(basename {{ FLATPAKS_FILE }}) | sort --reverse | xargs "-i{}" -d "\n" sh -c "flatpak remote-info --arch={{ arch }} --system flathub {} &>/dev/null && flatpak install --noninteractive -y {}" || true'
    set -euo pipefail
    chroot "$CMD" --volume "$(realpath "$(dirname {{ FLATPAKS_FILE }})")":/flatpak-list

# Install polkit rules
rootfs-include-polkit polkit="1":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if polkit == "0" { 'exit 0' } else { '' } }}
    set -euo pipefail
    install -D -m 0644 {{ git_root }}/src/polkit-1/rules.d/*.rules -t {{ rootfs }}/etc/polkit-1/rules.d

# Hook used for custom operations done in the rootfs before it is squashed.
# Meant to be used in a GH action.
hook-post-rootfs hook=HOOK_post_rootfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if hook == '' { 'exit 0' } else { '' } }}
    {{ chroot_function }}
    set -euo pipefail
    chroot "$(cat '{{ hook }}')"

# Hook used for custom operations done before the initramfs is generated.
# Meant to be used in a GH action.
hook-pre-initramfs hook=HOOK_pre_initramfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if hook == '' { 'exit 0' } else { '' } }}
    {{ chroot_function }}
    set -euo pipefail
    chroot "$(cat '{{ hook }}')"

# Remove the sysroot tree and configure live environment
rootfs-clean-sysroot:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -euo pipefail
    CMD='set -xeuo pipefail
    if [[ -d /app ]]; then
        rm -rf /sysroot /ostree
        apt clean
        rm -rf /var/cache/apt/archives/*
    fi
    # Mask systemd-networkd-wait-online to prevent boot delays
    systemctl mask systemd-networkd-wait-online.service'
    chroot "$CMD"

# Compress rootfs into a compressed image
squash fs_type="squashfs":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    CMD='{{ if fs_type == "squashfs" { "mksquashfs $0 $1/squashfs.img -all-root -noappend" } else if fs_type == "erofs" { "mkfs.erofs -d0 --quiet --all-root -zlz4hc,6 -Eall-fragments,fragdedupe=inode -C1048576 $1/squashfs.img $0" } else { error(style('error') + "ERROR[squash]" + NORMAL + ": Invalid Compression") } }}'
    {{ compress_dependencies }}
    {{ builder_function }}
    set -euo pipefail
    BUILDER="$(compress_dependencies)"
    if ! (( BUILDER )); then
        bash -c "$CMD" "$(realpath {{ rootfs }})" "$(realpath {{ workdir }})"
    else
        CMD="apt-get update && apt-get install -y {{ if fs_type == 'squashfs' { 'squashfs-tools' } else if fs_type == 'erofs' { 'erofs-utils' } else { '' } }} ; $CMD"
        builder "$CMD" "/app/{{ rootfs }}" "/app/{{ workdir }}"
    fi

# Expand grub templace, according to the image os-release.
process-grub-template $extra_kargs="snow-linux.live=1":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    kargs=()
    IFS=',' read -r -a kargs <<< "$extra_kargs"
    if [[ "$extra_kargs" == "NONE" ]]; then
        kargs=()
    fi

    OS_RELEASE="{{ rootfs }}/usr/lib/os-release"
    TMPL="src/grub.cfg.tmpl"
    DEST="{{ isoroot }}/boot/grub/grub.cfg"
    # TODO figure out a better mechanism
    PRETTY_NAME="$(source "$OS_RELEASE" >/dev/null && echo "${PRETTY_NAME/ (*)}")"
    sed \
        -e "s|@PRETTY_NAME@|${PRETTY_NAME}|g" \
        -e "s|@EXTRA_KARGS@|${kargs[*]}|g" \
        "$TMPL" >"$DEST"

# Install Secure Boot signed packages into rootfs
rootfs-install-secureboot:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -euo pipefail
    CMD='set -xeuo pipefail
    apt-get update
    apt-get install -y shim-signed grub-efi-amd64-signed grub-efi-amd64-bin'
    chroot "$CMD"

# Prep the environment for the ISO
iso-organize extra_kargs: && (process-grub-template extra_kargs)
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    mkdir -p {{ isoroot }}/boot/grub {{ isoroot }}/LiveOS
    cp {{ rootfs }}/lib/modules/*/vmlinuz {{ isoroot }}/boot
    cp {{ workdir }}/initramfs.img {{ isoroot }}/boot
    # Hardcoded on the dmsquash-live source code unless specified otherwise via kargs
    # https://github.com/dracut-ng/dracut-ng/blob/0ffc61e536d1193cb837917d6a283dd6094cb06d/modules.d/90dmsquash-live/dmsquash-live-root.sh#L23
    {{ if env('CI', '') == '' { 'cp' } else { 'mv' } }} {{ workdir }}/squashfs.img {{ isoroot }}/LiveOS/squashfs.img

# Build the ISO from the compressed image
iso:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if env('CI', '') != '' { "echo '" + style('warning') + "In CI - Deleting: "  + rootfs + "...' " + NORMAL +"; rm -rf " + rootfs } else { '' } }}
    {{ iso_dependencies }}
    BUILDER="$(iso_dependencies)"
    CMD='set -xeuo pipefail
    ISOROOT="$0"
    WORKDIR="$1"
    ROOTFS="$2"
    apt-get update && apt-get install -y grub-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed xorriso dosfstools mtools {{ if arch == "aarch64" { 'grub-efi-arm64-bin grub-efi-arm64-signed' } else { '' } }}
    mkdir -p $ISOROOT/EFI/BOOT
    # ARCH_SHORT needs to be uppercase
    ARCH_SHORT="$(echo {{ arch }} | sed 's/x86_64/x64/g' | sed 's/aarch64/aa64/g')"
    ARCH_32="$(echo {{ arch }} | sed 's/x86_64/ia32/g' | sed 's/aarch64/arm/g')"

    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/BOOT.conf
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/grub.cfg


    ARCH_GRUB="$(echo {{ arch }} | sed 's/x86_64/i386-pc/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_OUT="$(echo {{ arch }} | sed 's/x86_64/i386-pc-eltorito/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_MODULES="$(echo {{ arch }} | sed 's/x86_64/biosdisk/g' | sed 's/aarch64/efi_gop/g')"

    # Create BIOS boot image for legacy boot (using Debian grub-mkimage)
    grub-mkimage -O $ARCH_OUT -d /usr/lib/grub/$ARCH_GRUB -o $ISOROOT/boot/eltorito.img -p /boot/grub iso9660 $ARCH_MODULES

    # Create EFI boot image with Secure Boot support
    # Instead of using grub-mkrescue (which creates unsigned binaries),
    # we manually create an EFI System Partition with signed binaries
    dd if=/dev/zero of=$ISOROOT/../efiboot.img bs=1M count=10
    mkfs.vfat -F 12 -n "TITANOBOOT" $ISOROOT/../efiboot.img

    # Mount and populate with signed EFI binaries and GRUB modules
    EFIBOOT_MNT=$(mktemp -d)
    mount -o loop $ISOROOT/../efiboot.img $EFIBOOT_MNT
    mkdir -p $EFIBOOT_MNT/EFI/BOOT
    mkdir -p $EFIBOOT_MNT/boot/grub/x86_64-efi

    # Copy signed binaries for Secure Boot (Debian paths)
    if [ "{{ arch }}" == "x86_64" ] && [ -f "$ROOTFS/usr/lib/shim/shimx64.efi.signed" ]; then
        echo "Installing Secure Boot signed binaries to EFI partition..."
        cp -v "$ROOTFS/usr/lib/shim/shimx64.efi.signed" "$EFIBOOT_MNT/EFI/BOOT/BOOTX64.EFI"
        cp -v "$ROOTFS/usr/lib/shim/mmx64.efi.signed" "$EFIBOOT_MNT/EFI/BOOT/mmx64.efi"
        if [ -f "$ROOTFS/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" ]; then
            cp -v "$ROOTFS/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$EFIBOOT_MNT/EFI/BOOT/grubx64.efi"
        fi
        # Also copy to ISO root for dual boot support
        cp -v "$ROOTFS/usr/lib/shim/shimx64.efi.signed" "$ISOROOT/EFI/BOOT/BOOTX64.EFI"
        cp -v "$ROOTFS/usr/lib/shim/mmx64.efi.signed" "$ISOROOT/EFI/BOOT/mmx64.efi"
        if [ -f "$ROOTFS/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" ]; then
            cp -v "$ROOTFS/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$ISOROOT/EFI/BOOT/grubx64.efi"
        fi
    fi

    # Copy GRUB EFI modules from builder (Debian path: /usr/lib/grub/x86_64-efi)
    if [ -d "/usr/lib/grub/x86_64-efi" ]; then
        cp -r /usr/lib/grub/x86_64-efi/*.mod "$EFIBOOT_MNT/boot/grub/x86_64-efi/" 2>/dev/null || true
        cp -r /usr/lib/grub/x86_64-efi/*.lst "$EFIBOOT_MNT/boot/grub/x86_64-efi/" 2>/dev/null || true
    fi

    # Copy GRUB configuration
    cp -v $ISOROOT/boot/grub/grub.cfg $EFIBOOT_MNT/EFI/BOOT/grub.cfg
    cp -v $ISOROOT/boot/grub/grub.cfg $EFIBOOT_MNT/boot/grub/grub.cfg

    umount $EFIBOOT_MNT
    rmdir $EFIBOOT_MNT

    ARCH_SPECIFIC=()
    if [ "{{ arch }}" == "x86_64" ] ; then
        ARCH_SPECIFIC=("--grub2-mbr" "/usr/lib/grub/i386-pc/boot_hybrid.img")
    fi

    xorrisofs \
        -R \
        -V titanoboa_boot \
        -partition_offset 16 \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
        $ISOROOT/../efiboot.img \
        -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
        -c boot.cat --boot-catalog-hide \
        -b boot/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e \
        --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -vvvvv \
        -iso-level 3 \
        -o /app/output.iso \
        "${ARCH_SPECIFIC[@]}" \
        $ISOROOT'
    set -euo pipefail
    if ! (( BUILDER )); then
        bash -c "$CMD" "$(realpath {{ isoroot }})" "$(realpath {{ workdir }})" "$(realpath {{ rootfs }})"
    else
        {{ if `systemd-detect-virt -c || true` != 'none' { "echo '" + style('error') + "ERROR[iso]" + NORMAL + ": Cannot run in nested containers'; exit 1" } else { '' } }}
        {{ builder_function }}
        builder "$CMD" "/app/{{ isoroot }}" "/app/{{ workdir }}" "/app/{{ rootfs }}"
    fi

# TODO update this recipe parameters. Make it actually usable
[no-exit-message]
[doc('Build a live-iso')]
@build image=default_image flatpaks_file="src/flatpaks.example.txt" compression="squashfs" extra_kargs="snow-linux.live=1" container_image=image polkit="1": \
    checkroot \
    (show-config image flatpaks_file compression extra_kargs container_image polkit) \
    clean \
    init-work \
    (rootfs image) \
    rootfs-install-secureboot \
    (hook-pre-initramfs HOOK_pre_initramfs) \
    initramfs \
    (rootfs-include-flatpaks flatpaks_file) \
    (rootfs-include-polkit polkit) \
    (rootfs-include-container container_image image) \
    (hook-post-rootfs HOOK_post_rootfs) \
    rootfs-clean-sysroot \
    (ci-delete-image image) \
    (squash compression) \
    (iso-organize extra_kargs) \
    iso
    mv ./output.iso {{ justfile_dir() }} &>/dev/null


@show-config image flatpaks_file compression extra_kargs container_image polkit:
    echo "Using the following configuration:"
    echo "{{ style('warning') }}################################################################################{{ NORMAL }}"
    echo "PODMAN             := {{ PODMAN }}"
    echo "workdir            := {{ workdir }}"
    echo "isoroot            := {{ isoroot }}"
    echo "rootfs             := {{ rootfs }}"
    echo "builder_distro     := {{ builder_distro }}"
    echo "builder_image      := {{ builder_image }}"
    echo "HOOK_post_rootfs   := {{ if HOOK_post_rootfs =~ '(^$|^(?i)\bnone\b$)' { '' } else { canonicalize(HOOK_post_rootfs) } }}"
    echo "HOOK_pre_initramfs := {{ if HOOK_pre_initramfs =~ '(^$|^(?i)\bnone\b$)' { '' } else { canonicalize(HOOK_pre_initramfs) } }}"
    echo "image              := {{ image }}"
    echo "flatpaks_file      := {{ if flatpaks_file =~ '(^$|^(?i)\bnone\b$)' { '' } else { canonicalize(flatpaks_file) } }}"
    echo "compression        := {{ compression }}"
    echo "extra_kargs        := {{ extra_kargs }}"
    echo "container_image    := {{ container_image || image }}"
    echo "polkit             := {{ polkit }}"
    echo "CI                 := {{ env('CI', '') }}"
    echo "ARCH               := {{ arch }}"
    echo "{{ style('warning') }}################################################################################{{ NORMAL }}"
    sleep 1


[no-exit-message]
@checkroot:
    if [ `id -u` -gt 0 ]; then echo '{{ style("error") }}ERROR[build]{{ NORMAL }}: Must be root to build ISO' >&2 && exit 1; fi

@clean:
    echo "{{ style('command') }}cleaning {{ absolute_path(workdir) }}...{{ NORMAL }}" >&2
    rm -rf {{ absolute_path(workdir) }}

[private]
delete-image image:
    #!/usr/bin/env bash
    set -xeuo pipefail
    {{ PODMAN }} rmi --force "{{ image }}" || :

[private]
ci-delete-image image:
    #!/usr/bin/env bash
    set -xeuo pipefail
    if [[ -n "${CI:-}" ]]; then
        {{ PODMAN }} rmi --force {{ image }} || :
    fi

# Run VM with qemu
vm ISO_FILE *ARGS:
    #!/usr/bin/env bash
    qemu="qemu-system-{{ arch }}"
    if [[ ! $(type -P "$qemu") ]]; then
      qemu="flatpak run --command=$qemu org.virt_manager.virt-manager"
    fi
    $qemu \
        -enable-kvm \
        -M q35 \
        -cpu host \
        -smp $(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 )) \
        -m 4G \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::2222-:22 \
        -display gtk,show-cursor=on \
        -boot d \
        -cdrom {{ ISO_FILE }} {{ ARGS }}

# Run VM with a container and web vnc
container-run-vm ISO_FILE:
    #!/usr/bin/env bash
    set -xeuo pipefail
    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Ram Size
    mem_free=$(awk '/MemAvailable/ { printf "%.0f\n", $2/1024/1024 - 1 }' /proc/meminfo)
    ram_size=$(( mem_free > 64 ? mem_free / 2 : (mem_free > 8 ? 8 : (mem_free < 3 ? 3 : mem_free)) ))

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))")
    run_args+=(--env "RAM_SIZE=${ram_size}G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--env "BOOT_MODE=windows_secure")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "{{ canonicalize(ISO_FILE) }}":"/boot.iso")
    run_args+=(ghcr.io/qemus/qemu)

    # Run the VM and open the browser to connect
    {{ PODMAN }} run "${run_args[@]}" &
    xdg-open http://localhost:${port}

# Print the absolute of the files relative to the project dir.
[private]
whereis +FILE_PATHS:
    @realpath -e {{ FILE_PATHS }}

launch-incus:
    #!/usr/bin/env bash
    image_file=output.iso

    if [ ! -f "$image_file" ]; then
        echo "No image file found"
        exit 1
    fi

    abs_image_file=$(realpath "$image_file")

    instance_name="{{ instance_name }}"
    echo "Creating instance $instance_name from image file $abs_image_file"
    incus init "$instance_name" --empty --vm
    incus config device override "$instance_name" root size=50GiB
    incus config set "$instance_name" limits.cpu=4 limits.memory=16GiB
    incus config set "$instance_name" security.secureboot=true
    incus config device add "$instance_name" vtpm tpm
    incus config device add "$instance_name" install disk source="$abs_image_file" boot.priority=90
    incus start "$instance_name"
    echo "$instance_name is Starting..."
    incus console --type=vga "$instance_name"

rm-install:
    #!/usr/bin/env bash
    instance_name="{{ instance_name }}"
    echo "Removing install device from $instance_name"
    incus config device remove "$instance_name" install

start:
    #!/usr/bin/env bash
    instance_name="{{ instance_name }}"
    incus start "$instance_name" || true

console: start
    #!/usr/bin/env bash
    instance_name="{{ instance_name }}"
    incus console --type=vga "$instance_name"

qemu:
    #!/usr/bin/env bash
    instance_name="{{ instance_name }}"
    echo "Starting QEMU with instance $instance_name"
    qemu-system-x86_64 -enable-kvm -m 4G \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
    -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
    -cdrom output.iso

snow:
    sudo {{ just }} build
    scp output.iso  caddy:/mnt/caddy/snow-installer-latest.iso

snowfield:
    sudo {{ just }} build ghcr.io/frostyard/snowfield:latest
    scp output.iso  caddy:/mnt/caddy/snowfield-installer-latest.iso


upload:
    scp output.iso  caddy:/mnt/caddy/snow-installer-nbc.iso