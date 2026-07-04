#!/usr/bin/env bash
# Post-rootfs hook: put bootc-installer (GTK installer + fisherman backend)
# onto the live media, replacing the nbc-based install flow.
# Runs inside the extracted rootfs chroot; the titanoboa repo is at /app.
set -euxo pipefail

INSTALLER_VERSION="v3.0.14"
INSTALLER_BUNDLE="https://github.com/projectbluefin/bootc-installer/releases/download/${INSTALLER_VERSION}/org.bootcinstaller.Installer.flatpak"

# Install the installer Flatpak system-wide; the runtime comes from flathub.
flatpak remote-add --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
curl -fsSL -o /tmp/installer.flatpak "$INSTALLER_BUNDLE"
flatpak install --system --noninteractive -y /tmp/installer.flatpak
rm -f /tmp/installer.flatpak

# Live-session home must be under real /home, not /var/home: Flatpak gives
# sandboxes a private /var even with --filesystem=host, so a /var/home user
# breaks the installer's host-staging of fisherman/recipe/log (files land in
# the sandbox-private /var and the host-side pkexec launch cannot see them).
# Snow defaults HOME=/var/home with /home as a bind mount of it; on ephemeral
# live media a plain /home directory is fine.
systemctl mask home.mount
sed -i 's|^HOME=/var/home$|HOME=/home|' /etc/default/useradd

# Installer configuration (read from /run/host/etc inside the Flatpak sandbox).
install -D -m 0644 /app/src/bootc-installer/images.json /etc/bootc-installer/images.json
install -D -m 0644 /app/src/bootc-installer/recipe.json /etc/bootc-installer/recipe.json
install -D -m 0644 /app/src/bootc-installer/cosign.pub  /etc/bootc-installer/cosign.pub
touch /etc/bootc-installer/live-iso-mode

# Autostart the installer in the live session.
install -D -m 0644 /app/src/bootc-installer/bootc-installer-autostart.desktop \
    /etc/xdg/autostart/bootc-installer.desktop

# Polkit: let the "snow" live user run fisherman without a password.
install -D -m 0644 /app/src/bootc-installer/org.bootcinstaller.Installer.policy \
    /usr/share/polkit-1/actions/org.bootcinstaller.Installer.policy
install -D -m 0644 /app/src/bootc-installer/99-live-installer.rules \
    /etc/polkit-1/rules.d/99-live-installer.rules

# fisherman on a stable path (the polkit action annotation points here).
FISHERMAN=$(find /var/lib/flatpak/app/org.bootcinstaller.Installer -name fisherman -type f | head -1)
test -n "$FISHERMAN"

# Replace the bundle's fisherman with the frostyard build when staged in the
# repo (src/bootc-installer/fisherman, untracked): carries the composefs
# scratch-store pull fix and cosign verification until upstream releases them.
if [ -x /app/src/bootc-installer/fisherman ]; then
    install -m 0755 /app/src/bootc-installer/fisherman "$FISHERMAN"
    echo "Replaced bundle fisherman with frostyard build"
fi

mkdir -p /usr/local/bin
ln -sf "$FISHERMAN" /usr/local/bin/fisherman

echo "bootc-installer live media setup complete"
