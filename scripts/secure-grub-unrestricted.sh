#!/bin/bash
# ==============================================================================
# QUBES OS (DOM0) GRUB HARDENING SCRIPT - UNRESTRICTED DEFAULT BOOT
# Usage: sudo ./secure-qubes-grub.sh
# ========================================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "[-] Warning: Qubes OS signature not detected in /etc/os-release." >&2
    echo "    Ensure you are running this explicitly inside dom0." >&2
fi

if [ -z "${1:-}" ]; then
    echo "[-] Error: Missing password argument." >&2
    echo "    Usage: sudo $0 'your_secure_password'" >&2
    exit 1
fi


PLAIN_PASSWORD="$1"
GRUB_USER="$2"

echo "[+] Phase 1: Checking and temporarily remounting boot directories if needed..."
if mount | grep -E " on /boot type .* \(ro," > /dev/null; then
    echo "[*] /boot filesystem is currently Read-Only. Remounting writeable..."
    mount -o remount,rw /boot
fi

echo "[+] Phase 2: Generating salted PBKDF2 hash using Qubes/Fedora binaries..."
if grub-mkpasswd-pbkdf2 --version >/dev/null 2>&1; then
    GRUB_MKPASSWD_CMD="grub-mkpasswd-pbkdf2"
else
    echo "[-] Error: grub-mkpasswd-pbkdf2 tool not found." >&2
    exit 1
fi

RAW_HASH=$(echo -e "${PLAIN_PASSWORD}\n${PLAIN_PASSWORD}" | "$GRUB_MKPASSWD_CMD" | grep -oE "grub\.pbkdf2\.sha512\.[0-9]+\.[A-F0-9]+\.[A-F0-9]+")

if [ -z "$RAW_HASH" ]; then
    echo "[-] Error: Failed to generate cryptographic hash." >&2
    exit 1
fi

echo "[+] Phase 3: Writing superuser credentials into custom configuration..."
CUSTOM_CONFIG_FILE="/etc/grub.d/40_custom"

if [ -f "$CUSTOM_CONFIG_FILE" ]; then
    cp "$CUSTOM_CONFIG_FILE" "${CUSTOM_CONFIG_FILE}.bak"
fi

cat << EOF > "$CUSTOM_CONFIG_FILE"
#!/bin/sh
exec tail -n +3 \$0
set superusers="${GRUB_USER}"
password_pbkdf2 ${GRUB_USER} ${RAW_HASH}
EOF
chmod +x "$CUSTOM_CONFIG_FILE"

echo "[+] Phase 4: Patching Qubes OS Linux & Xen templates for --unrestricted boot..."
# Qubes OS heavily uses 20_linux_xen alongside 10_linux for primary virtualization entries
TEMPLATES=("/etc/grub.d/10_linux" /etc/grub.d/20_linux_xen*)

for template in "${TEMPLATES[@]}"; do
    if [ -f "$template" ]; then
        echo "[*] Injecting unrestricted flag into: $template"
        cp "$template" "${template}.bak"
        
        # Inject flag into class markers to automatically cover generated menus
        if grep -q "CLASS=\"--class gnu-linux" "$template"; then
            sed -i 's/CLASS="--class gnu-linux/CLASS="--unrestricted --class gnu-linux/g' "$template"
        fi
        if grep -q "CLASS=\"--class gnu" "$template"; then
            sed -i 's/CLASS="--class gnu/CLASS="--unrestricted --class gnu/g' "$template"
        fi
        
        # Catch explicit internal echo blocks used inside Xen templates
        sed -i 's/echo "menuentry /echo "menuentry --unrestricted /g' "$template"
    fi
done

echo "[+] Phase 5: Routing output layout targets..."
# In Qubes R4.2+, the standard configuration maps to /boot/grub2/grub.cfg for unified builds
GRUB_CFG_PATH="/boot/grub/grub.cfg"

# Support fallback mapping checks for EFI configurations
if [ -f "/boot/efi/EFI/qubes/grub.cfg" ]; then
    GRUB_CFG_PATH="/boot/efi/EFI/qubes/grub.cfg"
fi

echo "[*] Target configuration path identified: $GRUB_CFG_PATH"
if [ -f "$GRUB_CFG_PATH" ]; then
    cp "$GRUB_CFG_PATH" "${GRUB_CFG_PATH}.bak"
fi

echo "[+] Phase 6: Executing grub-mkconfig pipeline..."
sudo grub-mkconfig -o "$GRUB_CFG_PATH"

echo "[+] Phase 7: Verification scan..."
# Ensure that your primary Xen or Linux entry points contain the required override flag
if grep -q "menuentry " "$GRUB_CFG_PATH"; then
    echo "[*] Scanning active boot paths for safety..."
    if grep "menuentry " "$GRUB_CFG_PATH" | grep -v "--unrestricted" > /dev/null; then
        echo "[!] Warning: Some menu entries might still require a password to boot automatically."
    else
        echo "[+] Success: All menu entries have been securely set to --unrestricted."
    fi
fi

echo "[+] GRUB Hardening for Qubes OS complete."
echo "[+] Normal system boot: UNRESTRICTED (No password needed)"
echo "[+] Console interface (c) and Argument Editing (e): LOCKED for u
ser '${GRUB_USER}'"
