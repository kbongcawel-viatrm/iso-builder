#!/bin/bash
# tpm_enable_debian.sh
# Debian/Ubuntu script to check for TPM 2.0, load kernel modules, install tpm2-tools, and probe TPM.

set -euo pipefail

echo "== TPM2 re-enable & diagnostic script (Debian/Ubuntu) =="
echo

if [ "$EUID" -ne 0 ]; then
  echo "This script requires root. Re-run with sudo."
  exit 2
fi

# 1) Detect TPM device nodes
echo "1) Checking device nodes..."
DEV_FOUND=0
for d in /dev/tpm0 /dev/tpmrm0; do
  if [ -e "$d" ]; then
    echo "  Found device: $d"
    DEV_FOUND=1
  fi
done
if [ $DEV_FOUND -eq 0 ]; then
  echo "  No /dev/tpm0 or /dev/tpmrm0 found."
fi
echo

# 2) Ensure kernel modules are loaded
echo "2) Loading kernel modules..."
modules=(tpm tpm_tis tpm_dev tpm_crb tpm_tis_core)
for m in "${modules[@]}"; do
  if lsmod | grep -q "^${m}"; then
    echo "  Module already loaded: $m"
  else
    echo -n "  Loading: $m ... "
    if modprobe "$m" 2>/dev/null; then
      echo "ok"
    else
      echo "failed (may not be present or not needed)"
    fi
  fi
done
echo

# 3) Ensure tpm2-tools installed (apt)
echo "3) Checking tpm2-tools package..."
TPM_VERSION=$(tpm2-tools --version)
if $TPM_VERSION >/dev/null 2>&1; then
  echo "tpm2-tools already installed."
else
    sudo apt update && sudo apt install -y tpm2-tools
    if $TPM_VERSION >/dev/null 2>&1; then
    echo "tpm tools is now installed. Running on ${TPM_VERSION}"
  else
    echo "Skipping install. Failed to install"
  fi
fi

# 4) Probe TPM using tpm2-tools if available
echo "4) Probing TPM with tpm2-tools..."
if command -v tpm2_getrandom >/dev/null 2>&1; then
  echo "  tpm2_getrandom (3 bytes):"
  if tpm2_getrandom 3 >/dev/null 2>&1; then
    tpm2_getrandom 3 | xxd -p
    echo "  tpm2_getrandom succeeded — TPM is accessible."
  else
    echo "  tpm2_getrandom failed."
  fi

  echo
  echo "  tpm2_getcap properties-fixed:"
  if tpm2_getcap properties-fixed >/dev/null 2>&1; then
    tpm2_getcap properties-fixed
  else
    echo "  tpm2_getcap failed."
  fi
else
  echo "  tpm2-tools not available; cannot probe. Install and re-run this script."
fi
echo

# 5) Check systemd journal and dmesg for TPM messages
echo "5) Checking kernel messages for TPM..."
echo "  Last 200 dmesg lines with 'tpm' or 'TPM':"
dmesg | tail -n 200 | egrep -i 'tpm|TPM' || true
echo
if command -v journalctl >/dev/null 2>&1; then
  echo "  Recent journal entries containing 'tpm' (last 200 lines):"
  journalctl -k -n 200 | egrep -i 'tpm|TPM' || true
fi
echo

# 6) Helpful next steps
echo "6) Next steps / notes:"
if [ $DEV_FOUND -eq 0 ]; then
  echo "  - No TPM device node found; TPM may be disabled in firmware (UEFI/BIOS)."
  echo "  - Reboot and enable 'TPM', 'PTT' (Intel Platform Trust Technology), or 'fTPM' (AMD) in firmware."
  echo "  - After enabling, reboot into Linux and re-run this script."
else
  echo "  - If tpm2-tools commands failed but device node exists, try unloading/loading modules or check firmware."
  echo "  - You can run: ls -l /dev/tpm* ; sudo modprobe -r tpm_tis && sudo modprobe tpm_tis"
fi

echo
echo "Script finished."
