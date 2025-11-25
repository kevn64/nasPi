#!/usr/bin/env bash
#
# Raspberry Pi NAS setup script (TWO USB DRIVES)
# - Mounts two USB drives at /mnt/usb1 and /mnt/usb2
# - Shares them over SMB as \\raspberrypi\USB1 and \\raspberrypi\USB2
# - Enables mDNS so raspberrypi.local works
#
# BEFORE RUNNING:
#   - Plug in your USB sticks
#   - Values below are set from your lsblk output

### CONFIGURATION ###

PI_USER="dan"              # Raspberry Pi login user

DEVICE1="/dev/sda1"        # First USB partition 
MOUNT_POINT1="/mnt/usb1"
SHARE_NAME1="USB1"

DEVICE2="/dev/sdb1"        # Second USB partition 
MOUNT_POINT2="/mnt/usb2"
SHARE_NAME2="USB2"

ENABLE_JELLYFIN="false"    # Set to "true" if you want to try auto-installing Jellyfin

### END CONFIGURATION ###


# ===== Helper function: set up one USB drive =====

setup_usb_and_fstab() {
  local DEVICE="$1"
  local MOUNT_POINT="$2"
  local LABEL="$3"

  echo "------------------------------------------"
  echo "Configuring USB drive: $LABEL"
  echo "  Device      : $DEVICE"
  echo "  Mount point : $MOUNT_POINT"
  echo "------------------------------------------"

  if [ ! -b "$DEVICE" ]; then
    echo "ERROR: Block device '$DEVICE' not found for $LABEL."
    echo "Run 'lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT' to find the correct device, then edit this script."
    exit 1
  fi

  mkdir -p "$MOUNT_POINT"

  echo "Detecting filesystem type and UUID for $DEVICE..."
  local UUID
  local FSTYPE

  UUID=$(blkid -s UUID -o value "$DEVICE" || true)
  FSTYPE=$(blkid -s TYPE -o value "$DEVICE" || true)

  if [ -z "$UUID" ] || [ -z "$FSTYPE" ]; then
    echo "ERROR: Could not detect UUID or filesystem type for $DEVICE via blkid."
    echo "Make sure the drive is partitioned and formatted (e.g. FAT32, exFAT, NTFS, ext4)."
    exit 1
  fi

  echo "  UUID  : $UUID"
  echo "  TYPE  : $FSTYPE"
  echo

  local FSTAB_LINE
  FSTAB_LINE="UUID=${UUID}  ${MOUNT_POINT}  ${FSTYPE}  defaults,uid=${PI_UID},gid=${PI_GID},umask=000  0  0"

  echo "Adding entry to /etc/fstab for $LABEL if not already present..."
  if grep -q "$UUID" /etc/fstab; then
    echo "fstab entry with this UUID already exists. Skipping add."
  else
    echo "$FSTAB_LINE" >> /etc/fstab
    echo "Added:"
    echo "  $FSTAB_LINE"
  fi
}


# ===== Main Script =====

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run this script with sudo:"
  echo "  sudo ./setup_pi_nas_dual.sh"
  exit 1
fi

if ! id "$PI_USER" >/dev/null 2>&1; then
  echo "User '$PI_USER' not found. Edit PI_USER in the script and try again."
  exit 1
fi

PI_UID=$(id -u "$PI_USER")
PI_GID=$(id -g "$PI_USER")

echo "Using configuration:"
echo "  Pi user      : $PI_USER (uid=$PI_UID gid=$PI_GID)"
echo "  Drive 1      : $DEVICE1 -> $MOUNT_POINT1 -> share [$SHARE_NAME1]"
echo "  Drive 2      : $DEVICE2 -> $MOUNT_POINT2 -> share [$SHARE_NAME2]"
echo


# ---- Install required packages ----

echo "Updating apt and installing required packages..."
apt update
apt install -y usbutils exfat-fuse exfatprogs ntfs-3g samba avahi-daemon
echo "Packages installed."
echo


# ---- Configure both USB mounts ----

setup_usb_and_fstab "$DEVICE1" "$MOUNT_POINT1" "$SHARE_NAME1"
setup_usb_and_fstab "$DEVICE2" "$MOUNT_POINT2" "$SHARE_NAME2"

echo "Mounting all filesystems (mount -a)..."
mount -a

if mountpoint -q "$MOUNT_POINT1"; then
  echo "Success: $MOUNT_POINT1 is mounted."
else
  echo "ERROR: $MOUNT_POINT1 is not mounted. Check /etc/fstab and 'sudo journalctl -xe'."
  exit 1
fi

if mountpoint -q "$MOUNT_POINT2"; then
  echo "Success: $MOUNT_POINT2 is mounted."
else
  echo "ERROR: $MOUNT_POINT2 is not mounted. Check /etc/fstab and 'sudo journalctl -xe'."
  exit 1
fi
echo


# ---- Configure Samba shares ----

SMB_CONF="/etc/samba/smb.conf"
BACKUP_CONF="/etc/samba/smb.conf.backup_pre_pi_nas_dual"

if [ ! -f "$BACKUP_CONF" ]; then
  echo "Backing up original Samba config to $BACKUP_CONF"
  cp "$SMB_CONF" "$BACKUP_CONF"
fi

add_samba_share() {
  local SHARE_NAME="$1"
  local SHARE_PATH="$2"

  echo "Ensuring Samba share [$SHARE_NAME] is configured..."

  if grep -q "^\[$SHARE_NAME\]" "$SMB_CONF"; then
    echo "Share [$SHARE_NAME] already exists in smb.conf. Not adding duplicate."
  else
    cat <<EOF >> "$SMB_CONF"

[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = yes
   writeable = yes
   public = yes
   guest ok = yes
   create mask = 0777
   directory mask = 0777
   force user = $PI_USER
EOF

    echo "Added Samba share [$SHARE_NAME] pointing to $SHARE_PATH"
  fi
}

add_samba_share "$SHARE_NAME1" "$MOUNT_POINT1"
add_samba_share "$SHARE_NAME2" "$MOUNT_POINT2"

echo "Restarting Samba services..."
systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd
echo "Enabling Samba services at boot..."
systemctl enable smbd nmbd 2>/dev/null || systemctl enable smbd
echo


# ---- Enable Avahi (mDNS) ----

echo "Enabling and starting avahi-daemon (for raspberrypi.local discovery)..."
systemctl enable avahi-daemon
systemctl start avahi-daemon
echo


# ---- Optional: Jellyfin install ----

if [ "$ENABLE_JELLYFIN" = "true" ]; then
  echo "Attempting to install Jellyfin via apt..."
  apt install -y jellyfin || echo "Jellyfin installation via apt failed. Install it manually later."
  systemctl enable jellyfin 2>/dev/null || true
  systemctl start jellyfin 2>/dev/null || true
else
  echo "Skipping Jellyfin installation (ENABLE_JELLYFIN=false)."
  echo "You can install it later and point libraries at:"
  echo "  $MOUNT_POINT1"
  echo "  $MOUNT_POINT2"
fi

echo
echo "=========================================="
echo " Raspberry Pi DUAL-USB NAS setup complete!"
echo "=========================================="
echo
echo "USB1:"
echo "  Device      : $DEVICE1"
echo "  Mount point : $MOUNT_POINT1"
echo "  Samba share : $SHARE_NAME1"
echo
echo "USB2:"
echo "  Device      : $DEVICE2"
echo "  Mount point : $MOUNT_POINT2"
echo "  Samba share : $SHARE_NAME2"
echo
echo "On Windows, access:"
echo "  \\\\raspberrypi\\$SHARE_NAME1"
echo "  \\\\raspberrypi\\$SHARE_NAME2"
echo
echo "On Steam Deck / Linux, use:"
echo "  smb://raspberrypi/$SHARE_NAME1"
echo "  smb://raspberrypi/$SHARE_NAME2"
echo
echo "If your Pi uses a different hostname or static IP, replace 'raspberrypi' accordingly."
echo "Done."
