#!/bin/bash
# save at /usr/local/bin/system-freeze.sh
# ==============================================================================
# STAGE 2: RUNTIME INIT HARDENING
# This script locks volatile spaces immediately before network/apps initiate.
# ==============================================================================
set -euo pipefail

echo "[BOOT INIT] Securing shared runtime permissions..."
# Ensure permissions on /tmp are properly masked even across dynamic mounts
chmod 1777 /tmp
chmod 1777 /dev/shm

echo "[BOOT INIT] Freezing filesystems against runtime alteration..."
# Explicitly seal the sysfs and block layers where possible to halt raw alterations
# If utilizing containers, this prevents accidental layout escalations
if [ -d /proc/sys/fs/protected_symlinks ]; then
    echo 1 > /proc/sys/fs/protected_symlinks
    echo 1 > /proc/sys/fs/protected_hardlinks
fi

echo "[BOOT INIT] CRISIS LOCK: Permanently disabling runtime module loading..."
# Setting this to 1 prevents ANY software (including root) from loading or unloading
# kernel modules until the next physical hardware reset/reboot.
sysctl -w kernel.modules_disabled=1

echo "[BOOT INIT] Core kernel environment frozen successfull
y."
