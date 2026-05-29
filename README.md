## Qubes GitHub Runner Repo Files

Copy each section into the matching path.


## `.github/workflows/qubes-bootstrap.yml`

```yaml
name: Prepare Qubes installer disk

on:
  workflow_dispatch:
    inputs:
      target_disk:
        description: "Target disk to overwrite. Example: /dev/sda"
        required: true
        default: "/dev/sda"
      qubes_version:
        description: "Qubes OS release version"
        required: true
        default: "4.2.4"
      qubes_iso_url:
        description: "Optional direct HTTPS Qubes ISO URL. Leave blank to use kernel.org mirror."
        required: false
        default: ""
      qubes_iso_sha256:
        description: "Optional SHA256 checksum. Strongly recommended."
        required: false
        default: ""
      confirm_destroy:
        description: "Type DESTROY-/dev/sda-QUBES for the default target"
        required: true
        default: "NO"
      allow_root_disk_target:
        description: "Use YES only if runner is booted from a separate live OS."
        required: true
        default: "NO"
        type: choice
        options: ["NO", "YES"]

permissions:
  contents: read

concurrency:
  group: qubes-installer-disk-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  prepare-installer-disk:
    runs-on: [self-hosted, linux]
    timeout-minutes: 180
    env:
      TARGET_DISK: ${{ inputs.target_disk }}
      QUBES_VERSION: ${{ inputs.qubes_version }}
      QUBES_ISO_URL: ${{ inputs.qubes_iso_url }}
      QUBES_ISO_SHA256: ${{ inputs.qubes_iso_sha256 }}
      CONFIRM_DESTROY: ${{ inputs.confirm_destroy }}
      ALLOW_ROOT_DISK_TARGET: ${{ inputs.allow_root_disk_target }}
      WORKDIR: /var/tmp/qubes-installer-${{ github.run_id }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Safety notice
        shell: bash
        run: |
          set -euo pipefail
          cat <<'EOF'
          WARNING: This workflow writes a Qubes OS installer ISO to the selected disk.
          It is destructive. If TARGET_DISK is the runner's current OS disk, the job can
          destroy the runner and fail mid-run.

          Recommended: boot the laptop from a separate live Linux USB/external SSD,
          run the self-hosted runner there, and target the internal /dev/sda only
          when it is not the live runner's root disk.
          EOF

      - name: Validate repository scripts
        shell: bash
        run: |
          set -euo pipefail
          test -f scripts/make-qubes-installer-usb.sh
          test -f scripts/qubes-dom0-bootstrap.sh
          bash -n scripts/make-qubes-installer-usb.sh
          bash -n scripts/qubes-dom0-bootstrap.sh
          chmod +x scripts/*.sh

      - name: Validate confirmation and target disk
        shell: bash
        run: |
          set -euo pipefail
          expected="DESTROY-${TARGET_DISK}-QUBES"
          if [[ "${CONFIRM_DESTROY}" != "${expected}" ]]; then
            echo "::error::Confirmation failed. Expected: ${expected}"
            exit 1
          fi

          [[ "${TARGET_DISK}" == /dev/* ]] || { echo "::error::target_disk must be a /dev/... block path"; exit 1; }
          [[ -b "${TARGET_DISK}" ]] || { echo "::error::Target is not a block device: ${TARGET_DISK}"; lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL || true; exit 1; }

          target_real="$(readlink -f "${TARGET_DISK}")"
          if [[ "$(lsblk -no TYPE "${target_real}")" == "part" ]]; then
            echo "::error::Target must be a whole disk, not a partition: ${target_real}"
            exit 1
          fi

          root_source="$(findmnt -n -o SOURCE / || true)"
          root_disk=""
          if [[ -n "${root_source}" ]]; then
            root_real="$(readlink -f "${root_source}" || true)"
            root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null | head -n1 || true)"
            [[ -n "${root_parent}" ]] && root_disk="/dev/${root_parent}" || root_disk="${root_real}"
          fi

          echo "Target disk: ${TARGET_DISK} -> ${target_real}"
          echo "Root source: ${root_source}"
          echo "Root disk:   ${root_disk:-unknown}"

          if [[ -n "${root_disk}" ]] && [[ "$(readlink -f "${root_disk}")" == "${target_real}" ]]; then
            if [[ "${ALLOW_ROOT_DISK_TARGET}" != "YES" ]]; then
              echo "::error::Refusing: target appears to be the runner's root disk. Use a separate live OS or set allow_root_disk_target=YES only if you accept the risk."
              exit 1
            fi
            echo "::warning::Root disk override enabled. This may destroy the runner OS."
          fi

          lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "${target_real}" || true

      - name: Install required host packages
        shell: bash
        run: |
          set -euo pipefail
          if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y curl wget coreutils util-linux ca-certificates gnupg
          elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y curl wget coreutils util-linux ca-certificates gnupg2
          elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -Sy --noconfirm curl wget coreutils util-linux ca-certificates gnupg
          else
            echo "::warning::Unknown package manager. Assuming required tools already exist."
          fi
          for cmd in curl dd sync lsblk findmnt readlink sha256sum blockdev; do
            command -v "${cmd}" >/dev/null 2>&1 || { echo "::error::Missing ${cmd}"; exit 1; }
          done

      - name: Download Qubes ISO
        shell: bash
        run: |
          set -euo pipefail
          mkdir -p "${WORKDIR}"
          iso_path="${WORKDIR}/Qubes-R${QUBES_VERSION}-x86_64.iso"
          if [[ -n "${QUBES_ISO_URL}" ]]; then
            [[ "${QUBES_ISO_URL}" == https://* ]] || { echo "::error::qubes_iso_url must be HTTPS"; exit 1; }
            url="${QUBES_ISO_URL}"
          else
            url="https://mirrors.edge.kernel.org/qubes/iso/Qubes-R${QUBES_VERSION}-x86_64.iso"
          fi
          curl -fL --retry 5 --retry-delay 5 -o "${iso_path}" "${url}"
          if [[ -n "${QUBES_ISO_SHA256}" ]]; then
            printf '%s  %s\n' "${QUBES_ISO_SHA256}" "${iso_path}" | sha256sum -c -
          else
            echo "::warning::No SHA256 provided. Verify Qubes checksums/signatures manually."
            sha256sum "${iso_path}"
          fi
          echo "ISO_PATH=${iso_path}" >> "${GITHUB_ENV}"

      - name: Unmount target partitions
        shell: bash
        run: |
          set -euo pipefail
          target_real="$(readlink -f "${TARGET_DISK}")"
          while read -r mp; do
            [[ -n "${mp}" ]] || continue
            sudo umount "${mp}" || true
          done < <(lsblk -nrpo MOUNTPOINTS "${target_real}" | tr ' ' '\n' | grep -v '^$' || true)

      - name: Write Qubes installer ISO to target disk
        shell: bash
        run: |
          set -euo pipefail
          target_real="$(readlink -f "${TARGET_DISK}")"
          sudo blockdev --setrw "${target_real}" 2>/dev/null || true
          sudo dd if="${ISO_PATH}" of="${target_real}" bs=16M status=progress conv=fsync
          sync
          sudo blockdev --flushbufs "${target_real}" 2>/dev/null || true

      - name: Set target read-only for current session
        shell: bash
        run: |
          set -euo pipefail
          target_real="$(readlink -f "${TARGET_DISK}")"
          sudo blockdev --setro "${target_real}" 2>/dev/null || true
          sudo blockdev --getro "${target_real}" 2>/dev/null || true

      - name: Upload bootstrap scripts
        uses: actions/upload-artifact@v4
        with:
          name: qubes-bootstrap-scripts
          path: |
            scripts/make-qubes-installer-usb.sh
            scripts/qubes-dom0-bootstrap.sh

      - name: Final instructions
        shell: bash
        run: |
          cat <<'EOF'
          Qubes installer disk has been prepared.

          Next:
            1. Reboot the laptop.
            2. Boot from the prepared Qubes installer disk.
            3. Install Qubes OS manually.
            4. After first boot into Qubes dom0, copy scripts/qubes-dom0-bootstrap.sh into dom0.
            5. Run: chmod +x qubes-dom0-bootstrap.sh && sudo ./qubes-dom0-bootstrap.sh
          EOF
```


## `.gitignore`

```bash
build/
*.iso
*.img
*.log
.DS_Store
```


## `README.md`

```markdown
# Qubes GitHub Runner Repo

This repo prepares a Qubes OS installer disk from a Linux self-hosted GitHub Actions runner and includes the Qubes dom0 bootstrap script.

## Structure

```text
.
├── .github/
│   └── workflows/
│       └── qubes-bootstrap.yml
├── scripts/
│   ├── make-qubes-installer-usb.sh
│   └── qubes-dom0-bootstrap.sh
├── .gitignore
└── README.md
```

## Important warning

The workflow is destructive. If your self-hosted runner is running from `/dev/sda`, targeting `/dev/sda` can destroy the runner OS and fail mid-job.

Recommended:

```text
Boot laptop from separate Linux live USB/external SSD
  -> run GitHub self-hosted runner from that live environment
  -> target internal /dev/sda
  -> reboot into Qubes installer
  -> install Qubes OS manually
  -> run scripts/qubes-dom0-bootstrap.sh in dom0
```

## Workflow confirmation

For the default target `/dev/sda`, the confirmation input must be:

```text
DESTROY-/dev/sda-QUBES
```

Set `allow_root_disk_target` to `YES` only if you are booted from a separate live environment and accept the risk.

## After Qubes install

Copy `scripts/qubes-dom0-bootstrap.sh` into Qubes dom0:

```bash
chmod +x qubes-dom0-bootstrap.sh
sudo ./qubes-dom0-bootstrap.sh
```

## Bootstrap creates

```text
Named DisposableVMs:
  work-gmail
  work-github
  work-aws
  ssh-admin
  dev-containers
  untrusted

Rebuildable service qubes:
  adguard-dns
  aws-openvpn
  suricata-ips
  caddy-web
  portainer-mgmt

Persistent offline qube:
  vault
```

## Recreate app qubes

```bash
sudo qubes-recreate-compartment all-apps
```

## Recreate service qubes

```bash
sudo qubes-recreate-compartment adguard-dns
sudo qubes-recreate-compartment aws-openvpn
sudo qubes-recreate-compartment suricata-ips
sudo qubes-recreate-compartment caddy-web
sudo qubes-recreate-compartment portainer-mgmt
sudo ./qubes-dom0-bootstrap.sh
```
```


## `scripts/make-qubes-installer-usb.sh`

```bash
#!/usr/bin/env bash
# make-qubes-installer-usb.sh
#
# Minimal shell-only Qubes OS installer USB writer.
#
# What this does:
#   1. Writes the Qubes ISO to an entire USB device.
#   2. Optionally attempts to create a separate encrypted LUKS data partition
#      in unused USB space after the bootable ISO area.
#   3. Sets the USB block device read-only after writing on Linux.
#
# What this does NOT do:
#   - It does not encrypt the bootable Qubes installer area. Firmware/bootloaders
#     must be able to read that area before Linux is running.
#   - It does not install Qubes to your internal NVMe.
#
# Example:
#   sudo ./make-qubes-installer-usb.sh \
#     --iso-url "https://ftp.qubes-os.org/iso/Qubes-R4.2.4-x86_64.iso" \
#     --usb-device /dev/disk/by-id/usb-SanDisk_Ultra_1234567890-0:0 \
#     --sha256 "PUT_EXPECTED_SHA256_HERE" \
#     --confirm WRITE-QUBES-USB
#
# Disable optional encrypted data partition:
#   sudo ./make-qubes-installer-usb.sh ... --luks-data no

set -euo pipefail

ISO_URL=""
ISO_FILE=""
USB_DEVICE=""
EXPECTED_SHA256=""
CONFIRM=""
WORKDIR="${TMPDIR:-/tmp}/qubes-usb-writer"
BLOCK_SIZE="4M"
SET_READONLY="yes"
LUKS_DATA="yes"
LUKS_LABEL="QUBESDATA"
MIN_LUKS_MIB=512

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./make-qubes-installer-usb.sh --iso-url URL --usb-device DEVICE --confirm WRITE-QUBES-USB [options]
  sudo ./make-qubes-installer-usb.sh --iso-file PATH --usb-device DEVICE --confirm WRITE-QUBES-USB [options]

Required:
  --usb-device DEVICE       Entire USB disk device, preferably /dev/disk/by-id/...
  --confirm WRITE-QUBES-USB

Choose one:
  --iso-url URL             Download Qubes ISO from this HTTPS URL
  --iso-file PATH           Use existing Qubes ISO file

Options:
  --sha256 SHA256           Verify ISO checksum before writing
  --block-size SIZE         dd block size, default 4M
  --set-readonly yes|no     Set Linux block device read-only after writing, default yes
  --luks-data yes|no        Create encrypted LUKS data partition after ISO if space allows, default yes
  --luks-label LABEL        LUKS data partition label, default QUBESDATA
  --min-luks-mib MIB        Minimum free space required for LUKS data partition, default 512

Important:
  Use an entire disk device, not a partition.
  Good: /dev/disk/by-id/usb-...
  Good: /dev/sdb
  Bad:  /dev/sdb1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso-url)
      ISO_URL="${2:-}"; shift 2 ;;
    --iso-file)
      ISO_FILE="${2:-}"; shift 2 ;;
    --usb-device)
      USB_DEVICE="${2:-}"; shift 2 ;;
    --sha256)
      EXPECTED_SHA256="${2:-}"; shift 2 ;;
    --confirm)
      CONFIRM="${2:-}"; shift 2 ;;
    --block-size)
      BLOCK_SIZE="${2:-}"; shift 2 ;;
    --set-readonly)
      SET_READONLY="${2:-}"; shift 2 ;;
    --luks-data)
      LUKS_DATA="${2:-}"; shift 2 ;;
    --luks-label)
      LUKS_LABEL="${2:-}"; shift 2 ;;
    --min-luks-mib)
      MIN_LUKS_MIB="${2:-}"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root with sudo."
[[ "$CONFIRM" == "WRITE-QUBES-USB" ]] || die "Refusing to write USB. Pass --confirm WRITE-QUBES-USB."
[[ -n "$USB_DEVICE" ]] || die "Missing --usb-device."
[[ "$SET_READONLY" == "yes" || "$SET_READONLY" == "no" ]] || die "--set-readonly must be yes or no."
[[ "$LUKS_DATA" == "yes" || "$LUKS_DATA" == "no" ]] || die "--luks-data must be yes or no."
[[ "$MIN_LUKS_MIB" =~ ^[0-9]+$ ]] || die "--min-luks-mib must be a number."

if [[ -n "$ISO_URL" && -n "$ISO_FILE" ]]; then
  die "Use either --iso-url or --iso-file, not both."
fi

if [[ -z "$ISO_URL" && -z "$ISO_FILE" ]]; then
  die "Provide --iso-url or --iso-file."
fi

[[ "$(uname -s)" == "Linux" ]] || die "This minimal script supports Linux hosts only."

for cmd in lsblk findmnt dd sync stat awk sed grep readlink blockdev partprobe; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

if [[ "$LUKS_DATA" == "yes" ]]; then
  for cmd in parted cryptsetup mkfs.ext4; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing $cmd. Install parted cryptsetup e2fsprogs, or pass --luks-data no."
  done
fi

if [[ -n "$ISO_URL" ]]; then
  command -v curl >/dev/null 2>&1 || die "Missing curl."
  [[ "$ISO_URL" == https://* ]] || die "--iso-url must be HTTPS."
fi

if [[ -n "$EXPECTED_SHA256" ]]; then
  command -v sha256sum >/dev/null 2>&1 || die "Missing sha256sum."
fi

[[ -b "$USB_DEVICE" || -b "$(readlink -f "$USB_DEVICE")" ]] || die "USB device is not a block device: $USB_DEVICE"

USB_REAL="$(readlink -f "$USB_DEVICE")"
[[ -b "$USB_REAL" ]] || die "Resolved USB device is not a block device: $USB_REAL"

if lsblk -no TYPE "$USB_REAL" | grep -qx "part"; then
  die "Target appears to be a partition, not an entire disk: $USB_REAL"
fi

ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
ROOT_DISK=""
if [[ -n "$ROOT_SRC" ]]; then
  ROOT_SRC_REAL="$(readlink -f "$ROOT_SRC" || true)"
  if [[ -n "$ROOT_SRC_REAL" ]]; then
    ROOT_PKNAME="$(lsblk -no PKNAME "$ROOT_SRC_REAL" 2>/dev/null | head -n1 || true)"
    if [[ -n "$ROOT_PKNAME" ]]; then
      ROOT_DISK="/dev/${ROOT_PKNAME}"
    fi
  fi
fi

if [[ -n "$ROOT_DISK" && "$(readlink -f "$USB_REAL")" == "$(readlink -f "$ROOT_DISK")" ]]; then
  die "Refusing: target USB is the same disk as the running root filesystem."
fi

if lsblk -nrpo MOUNTPOINTS "$USB_REAL" | grep -q '[^[:space:]]'; then
  log "Mounted filesystems detected on target; unmounting target partitions..."
  while read -r mp; do
    [[ -n "$mp" ]] || continue
    umount "$mp" || die "Could not unmount $mp"
  done < <(lsblk -nrpo MOUNTPOINTS "$USB_REAL" | tr ' ' '\n' | grep -v '^$' || true)
fi

log "Target USB device:"
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINTS "$USB_REAL" || true

mkdir -p "$WORKDIR"

if [[ -n "$ISO_URL" ]]; then
  ISO_FILE="${WORKDIR}/qubes.iso"
  log "Downloading Qubes ISO..."
  curl -fL --retry 5 --retry-delay 5 -o "$ISO_FILE" "$ISO_URL"
else
  [[ -f "$ISO_FILE" ]] || die "ISO file not found: $ISO_FILE"
fi

if [[ -n "$EXPECTED_SHA256" ]]; then
  log "Verifying ISO SHA256..."
  printf '%s  %s\n' "$EXPECTED_SHA256" "$ISO_FILE" | sha256sum -c -
else
  log "WARNING: No SHA256 supplied. Verify the ISO using Qubes' official checksum/signature instructions."
fi

log "About to overwrite the entire USB device:"
log "  ISO:    $ISO_FILE"
log "  Target: $USB_REAL"
log "Sleeping 10 seconds. Press Ctrl+C now to abort."
sleep 10

log "Ensuring target block device is writable for image creation..."
blockdev --setrw "$USB_REAL" 2>/dev/null || true

log "Writing ISO to USB. This can take several minutes..."
dd if="$ISO_FILE" of="$USB_REAL" bs="$BLOCK_SIZE" status=progress conv=fsync

log "Flushing writes..."
sync
blockdev --flushbufs "$USB_REAL" 2>/dev/null || true
partprobe "$USB_REAL" 2>/dev/null || true
sleep 3

create_luks_data_partition() {
  local usb="$1"
  local iso="$2"
  local label="$3"
  local min_mib="$4"

  local usb_bytes iso_bytes usb_mib iso_mib start_mib free_mib part_name part_path mapper_name

  usb_bytes="$(blockdev --getsize64 "$usb")"
  iso_bytes="$(stat -c '%s' "$iso")"
  usb_mib="$(( usb_bytes / 1024 / 1024 ))"
  iso_mib="$(( (iso_bytes + 1024 * 1024 - 1) / 1024 / 1024 ))"

  # Leave padding after the ISO image so we do not disturb hybrid boot data.
  start_mib="$(( iso_mib + 64 ))"
  free_mib="$(( usb_mib - start_mib ))"

  if (( free_mib < min_mib )); then
    log "Skipping encrypted data partition: only ${free_mib} MiB free after ISO; need at least ${min_mib} MiB."
    return 0
  fi

  log "Attempting to add encrypted LUKS data partition:"
  log "  Start: ${start_mib} MiB"
  log "  Size:  about ${free_mib} MiB"
  log "  Label: ${label}"
  log "This partition is separate from the bootable Qubes installer area."

  # Some ISO-hybrid media have partition metadata that parted warns about.
  # We use yes to accept harmless fixes when the backup table is not at the end.
  yes | parted -s "$usb" ---pretend-input-tty print >/dev/null 2>&1 || true
  parted -s "$usb" unit MiB mkpart "$label" ext4 "${start_mib}" "100%" || {
    log "Could not create extra partition after the ISO. Bootable installer remains valid."
    log "Use a larger USB or create encrypted storage on a second USB."
    return 0
  }

  sync
  partprobe "$usb" 2>/dev/null || true
  sleep 5

  part_path="$(lsblk -nrpo NAME,TYPE "$usb" | awk '$2=="part"{print $1}' | tail -n1)"
  if [[ -z "$part_path" || ! -b "$part_path" ]]; then
    log "Could not locate newly-created partition. Skipping LUKS setup."
    return 0
  fi

  log "Creating LUKS2 container on ${part_path}."
  log "You will be prompted for the LUKS passphrase. This does not affect booting the Qubes installer."
  cryptsetup luksFormat --type luks2 "$part_path"

  mapper_name="qubes_usb_${label}"
  cryptsetup open "$part_path" "$mapper_name"
  mkfs.ext4 -L "$label" "/dev/mapper/${mapper_name}"
  cryptsetup close "$mapper_name"

  log "Encrypted data partition created: ${part_path}"
}

if [[ "$LUKS_DATA" == "yes" ]]; then
  create_luks_data_partition "$USB_REAL" "$ISO_FILE" "$LUKS_LABEL" "$MIN_LUKS_MIB"
fi

log "Final USB layout:"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINTS "$USB_REAL" || true

if [[ "$SET_READONLY" == "yes" ]]; then
  log "Setting USB block device read-only for this Linux session..."
  blockdev --setro "$USB_REAL" || log "Could not set block device read-only. Use a physical write-protect switch if available."
  log "Read-only status:"
  blockdev --getro "$USB_REAL" || true
fi

sync

log "Done. Safely remove the USB, then boot the Lenovo from it."
log "Read-only note: blockdev --setro is a host-side software flag. A physical write-protect switch is stronger."
log "Encryption note: the bootable installer itself is intentionally unencrypted; optional LUKS data is separate."
```


## `scripts/qubes-dom0-bootstrap.sh`

```bash
#!/usr/bin/env bash
# qubes-dom0-bootstrap.sh
#
# Run this in Qubes OS dom0 after installation.
#
# It creates a minimal compartment layout:
#   work-gmail       Named DisposableVM for Gmail-only browsing
#   work-github      Named DisposableVM for GitHub/Git work
#   work-aws         Named DisposableVM routed through aws-openvpn
#   ssh-admin        Named DisposableVM for SSH client work
#   dev-containers   Named DisposableVM with rootless-only Podman guard
#   adguard-dns      Rebuildable service qube: AdGuard Home + cloudflared DNS proxy
#   aws-openvpn      Rebuildable service qube: OpenVPN ProxyVM for AWS infrastructure
#   suricata-ips     Rebuildable service qube: Suricata IDS/IPS ProxyVM
#   caddy-web        Rebuildable service qube: rootless Caddy reverse proxy
#   portainer-mgmt   Rebuildable service qube: rootless Portainer for local Podman management
#   vault            Persistent offline vault for secrets and recovery codes
#   untrusted        Named DisposableVM for unsafe links/files
#
# It does not copy secrets, keys, tokens, or passwords.
# Keep private SSH keys in vault or on a hardware security key where possible.

set -euo pipefail

TEMPLATE="${TEMPLATE:-}"
NETVM="${NETVM:-sys-firewall}"
OFFLINE_NETVM=""
DISPVM_TEMPLATE="${DISPVM_TEMPLATE:-}"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_dom0() {
  if ! command -v qvm-create >/dev/null 2>&1; then
    die "qvm-create not found. Run this in Qubes dom0, not inside an AppVM."
  fi
}

choose_template() {
  if [[ -n "$TEMPLATE" ]]; then
    qvm-check "$TEMPLATE" >/dev/null 2>&1 || die "Template not found: $TEMPLATE"
    return
  fi

  if qvm-check fedora-40 >/dev/null 2>&1; then
    TEMPLATE="fedora-40"
  elif qvm-check fedora-39 >/dev/null 2>&1; then
    TEMPLATE="fedora-39"
  elif qvm-check debian-12-xfce >/dev/null 2>&1; then
    TEMPLATE="debian-12-xfce"
  elif qvm-check debian-12 >/dev/null 2>&1; then
    TEMPLATE="debian-12"
  else
    TEMPLATE="$(qvm-ls --raw-list --class TemplateVM | head -n1 || true)"
  fi

  [[ -n "$TEMPLATE" ]] || die "Could not find a TemplateVM."
}

vm_exists() {
  qvm-check "$1" >/dev/null 2>&1
}

create_appvm() {
  local name="$1"
  local label="$2"
  local netvm="$3"
  local mem="$4"
  local maxmem="$5"
  local private_size="${6:-}"

  if vm_exists "$name"; then
    log "Qube already exists: $name"
  else
    log "Creating $name from template $TEMPLATE..."
    qvm-create --class AppVM --template "$TEMPLATE" --label "$label" "$name"
  fi

  qvm-prefs "$name" netvm "$netvm"
  qvm-prefs "$name" memory "$mem"
  qvm-prefs "$name" maxmem "$maxmem"

  if [[ -n "$private_size" ]]; then
    qvm-volume resize "${name}:private" "$private_size" || true
  fi
}

create_dvm_template() {
  local name="$1"
  local label="$2"
  local netvm="$3"
  local mem="$4"
  local maxmem="$5"
  local private_size="${6:-}"

  if vm_exists "$name"; then
    log "Disposable template already exists: $name"
  else
    log "Creating disposable-template AppVM: $name"
    qvm-create --class AppVM --template "$TEMPLATE" --label "$label" "$name"
  fi

  qvm-prefs "$name" template_for_dispvms True
  qvm-prefs "$name" netvm "$netvm"
  qvm-prefs "$name" memory "$mem"
  qvm-prefs "$name" maxmem "$maxmem"
  qvm-prefs "$name" autostart false

  if [[ -n "$private_size" ]]; then
    qvm-volume resize "${name}:private" "$private_size" || true
  fi
}

create_named_dispvm() {
  local name="$1"
  local dvm_template="$2"
  local label="$3"
  local netvm="$4"
  local mem="$5"
  local maxmem="$6"

  if vm_exists "$name"; then
    local klass
    klass="$(qvm-prefs "$name" klass 2>/dev/null || true)"
    if [[ "$klass" != "DispVM" ]]; then
      log "WARNING: $name exists but is class $klass, not DispVM. Leaving it unchanged."
      return 0
    fi
    log "Named DisposableVM already exists: $name"
  else
    log "Creating named DisposableVM $name from template $dvm_template..."
    qvm-create --class DispVM --template "$dvm_template" --label "$label" "$name"
  fi

  qvm-prefs "$name" netvm "$netvm"
  qvm-prefs "$name" memory "$mem" || true
  qvm-prefs "$name" maxmem "$maxmem" || true
  qvm-prefs "$name" autostart false || true
}

create_recreate_tool() {
  log "Installing dom0 fresh-slate/recreate helper..."

  install -d -o root -g root -m 0755 /usr/local/sbin
  install -d -o root -g root -m 0755 /etc/systemd/system

  cat > /usr/local/sbin/qubes-recreate-compartment <<'EOF_RECREATE'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo qubes-recreate-compartment <name|all-apps|all-services>

Fast disposable recreation:
  sudo qubes-recreate-compartment work-gmail
  sudo qubes-recreate-compartment work-github
  sudo qubes-recreate-compartment work-aws
  sudo qubes-recreate-compartment ssh-admin
  sudo qubes-recreate-compartment dev-containers
  sudo qubes-recreate-compartment untrusted
  sudo qubes-recreate-compartment all-apps

Service qubes:
  sudo qubes-recreate-compartment adguard-dns
  sudo qubes-recreate-compartment aws-openvpn
  sudo qubes-recreate-compartment suricata-ips
  sudo qubes-recreate-compartment caddy-web
  sudo qubes-recreate-compartment portainer-mgmt
  sudo qubes-recreate-compartment all-services

Notes:
  - Named DisposableVM recreation deletes the current named disposable instance
    and recreates it from its disposable template.
  - Service qube recreation deletes local service state; export configs first.
  - This script is intentionally destructive.
EOF_USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || { usage; exit 2; }

target="$1"

app_spec() {
  case "$1" in
    work-gmail) echo "work-gmail dvm-work-gmail green adguard-dns 800 2000" ;;
    work-github) echo "work-github dvm-work-github blue adguard-dns 800 2500" ;;
    work-aws) echo "work-aws dvm-work-aws orange aws-openvpn 1000 3000" ;;
    ssh-admin) echo "ssh-admin dvm-ssh-admin purple adguard-dns 600 1200" ;;
    dev-containers) echo "dev-containers dvm-dev-containers yellow adguard-dns 1500 4000" ;;
    untrusted) echo "untrusted dvm-untrusted red adguard-dns 800 2000" ;;
    *) return 1 ;;
  esac
}

service_spec() {
  case "$1" in
    adguard-dns) echo "adguard-dns orange suricata-ips 800 2000 15G" ;;
    aws-openvpn) echo "aws-openvpn purple adguard-dns 800 2000 10G" ;;
    suricata-ips) echo "suricata-ips red sys-firewall 1000 3000 20G" ;;
    caddy-web) echo "caddy-web green adguard-dns 600 1500 10G" ;;
    portainer-mgmt) echo "portainer-mgmt blue adguard-dns 800 2000 10G" ;;
    *) return 1 ;;
  esac
}

recreate_app() {
  local spec name tmpl label netvm mem maxmem klass
  spec="$(app_spec "$1")" || die "Unknown app compartment: $1"
  read -r name tmpl label netvm mem maxmem <<<"$spec"

  qvm-check "$tmpl" >/dev/null 2>&1 || die "Missing disposable template: $tmpl"

  if qvm-check "$name" >/dev/null 2>&1; then
    klass="$(qvm-prefs "$name" klass 2>/dev/null || true)"
    [[ "$klass" == "DispVM" ]] || die "$name exists but is class $klass, not DispVM."
    qvm-shutdown --wait "$name" 2>/dev/null || true
    qvm-remove -f "$name"
  fi

  qvm-create --class DispVM --template "$tmpl" --label "$label" "$name"
  qvm-prefs "$name" netvm "$netvm"
  qvm-prefs "$name" memory "$mem" || true
  qvm-prefs "$name" maxmem "$maxmem" || true
  qvm-prefs "$name" autostart false || true
  echo "Recreated named disposable: $name"
}

recreate_service() {
  local spec name label netvm mem maxmem size
  spec="$(service_spec "$1")" || die "Unknown service compartment: $1"
  read -r name label netvm mem maxmem size <<<"$spec"

  echo "WARNING: This will delete service qube $name and its local config/logs."
  echo "Type RECREATE-$name to continue:"
  read -r confirm
  [[ "$confirm" == "RECREATE-$name" ]] || die "Confirmation failed."

  if qvm-check "$name" >/dev/null 2>&1; then
    qvm-shutdown --wait "$name" 2>/dev/null || true
    qvm-remove -f "$name"
  fi

  echo "Service qube removed. Rerun qubes-dom0-bootstrap.sh to recreate service wiring."
}

case "$target" in
  all-apps)
    for vm in work-gmail work-github work-aws ssh-admin dev-containers untrusted; do
      recreate_app "$vm"
    done
    ;;
  all-services)
    for vm in adguard-dns aws-openvpn suricata-ips caddy-web portainer-mgmt; do
      recreate_service "$vm"
    done
    ;;
  work-gmail|work-github|work-aws|ssh-admin|dev-containers|untrusted)
    recreate_app "$target"
    ;;
  adguard-dns|aws-openvpn|suricata-ips|caddy-web|portainer-mgmt)
    recreate_service "$target"
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
EOF_RECREATE

  chown root:root /usr/local/sbin/qubes-recreate-compartment
  chmod 0755 /usr/local/sbin/qubes-recreate-compartment

  cat > /etc/systemd/system/qubes-fresh-slate-on-boot.service <<'EOF_FRESH_BOOT'
[Unit]
Description=Recreate disposable app qubes on boot
After=qubesd.service
Wants=qubesd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qubes-recreate-compartment all-apps

[Install]
WantedBy=multi-user.target
EOF_FRESH_BOOT

  chown root:root /etc/systemd/system/qubes-fresh-slate-on-boot.service
  chmod 0644 /etc/systemd/system/qubes-fresh-slate-on-boot.service
  systemctl daemon-reload
  systemctl enable qubes-fresh-slate-on-boot.service || true
}

create_disp_template() {
  local name="$1"

  if vm_exists "$name"; then
    log "Disposable template already exists: $name"
  else
    log "Creating disposable template: $name"
    qvm-create --class AppVM --template "$TEMPLATE" --label gray "$name"
  fi

  qvm-prefs "$name" template_for_dispvms True
  qvm-prefs "$name" netvm "$NETVM"
  qvm-features "$name" appmenus-dispvm 1 || true
  DISPVM_TEMPLATE="$name"
}

write_notes_to_vm() {
  local vm="$1"
  local text="$2"

  qvm-run -p "$vm" "mkdir -p ~/QubesNotes && cat > ~/QubesNotes/README.txt" <<<"$text" || true
}

install_rootless_container_guard() {
  local vm="dvm-dev-containers"

  log "Installing rootless container guard inside disposable template ${vm}..."

  qvm-run -u root -p "$vm" 'cat > /usr/local/sbin/install-rootless-container-guard.sh' <<'EOF_GUARD_INSTALL'
#!/usr/bin/env bash
set -euo pipefail

real_podman=""
for candidate in /usr/bin/podman /bin/podman; do
  if [[ -x "$candidate" ]]; then
    real_podman="$candidate"
    break
  fi
done

if [[ -z "$real_podman" ]]; then
  cat >&2 <<'EOF'
Podman is not installed yet.

Install Podman in the TemplateVM, not dom0. Fedora template example:
  sudo dnf install -y podman slirp4netns fuse-overlayfs shadow-utils

Then rerun this dom0 script.
EOF
  exit 0
fi

install -d -o root -g root -m 0755 /usr/local/bin
install -d -o root -g root -m 0755 /etc/containers/containers.conf.d
install -d -o root -g root -m 0755 /etc/profile.d
install -d -o root -g root -m 0755 /etc/systemd/system/podman.service.d
install -d -o root -g root -m 0755 /etc/systemd/system/podman.socket.d

cat > /etc/containers/containers.conf.d/90-qubes-rootless-lockdown.conf <<'EOF_CONF'
# Qubes rootless container defaults.
# This file is advisory defaults; /usr/local/bin/podman enforces the main policy.
[containers]
userns = "keep-id"
no_new_privileges = true

[network]
default_rootless_network_cmd = "slirp4netns"
EOF_CONF

cat > /usr/local/bin/podman <<EOF_WRAPPER
#!/usr/bin/env bash
set -euo pipefail

REAL_PODMAN="${real_podman}"

reject() {
  printf 'podman policy refused: %s\n' "\$*" >&2
  exit 126
}

if [[ "\${EUID}" -eq 0 ]]; then
  reject "rootful podman is disabled in this qube. Run containers as the normal user."
fi

cmd="\${1:-}"
case "\$cmd" in
  run|create)
    shift
    for arg in "\$@"; do
      case "\$arg" in
        --privileged|--privileged=true)
          reject "--privileged is disabled"
          ;;
        --network=host|--net=host|--network=ns:*|--net=ns:*)
          reject "host/ns networking is disabled"
          ;;
        --pid=host|--ipc=host|--uts=host|--userns=host)
          reject "host namespaces are disabled"
          ;;
        --cap-add*|--device*|--security-opt=seccomp=unconfined|--security-opt=label=disable)
          reject "cap-add, device passthrough, and disabled security labels are disabled"
          ;;
      esac
    done

    exec "\$REAL_PODMAN" "\$cmd" \
      --user "\$(id -u):\$(id -g)" \
      --userns=keep-id \
      --security-opt=no-new-privileges \
      --cap-drop=all \
      --network=slirp4netns:allow_host_loopback=false \
      "\$@"
    ;;
  pod)
    shift
    subcmd="\${1:-}"
    case "\$subcmd" in
      create)
        shift
        for arg in "\$@"; do
          case "\$arg" in
            --network=host|--net=host|--pid=host|--ipc=host|--uts=host|--userns=host|--privileged|--privileged=true)
              reject "unsafe pod namespace option disabled"
              ;;
          esac
        done
        exec "\$REAL_PODMAN" pod create --userns=keep-id --network=slirp4netns:allow_host_loopback=false "\$@"
        ;;
      *)
        exec "\$REAL_PODMAN" pod "\$subcmd" "\${@:2}"
        ;;
    esac
    ;;
  machine|system)
    shift
    # Permit harmless informational subcommands, block service/socket style workflows.
    case "\${1:-}" in
      info|df|version|events|connection)
        exec "\$REAL_PODMAN" "\$cmd" "\$@"
        ;;
      *)
        reject "podman \$cmd is restricted in this qube"
        ;;
    esac
    ;;
  *)
    exec "\$REAL_PODMAN" "\$@"
    ;;
esac
EOF_WRAPPER

chmod 0755 /usr/local/bin/podman
chown root:root /usr/local/bin/podman
chmod 0644 /etc/containers/containers.conf.d/90-qubes-rootless-lockdown.conf
chown root:root /etc/containers/containers.conf.d/90-qubes-rootless-lockdown.conf

cat > /etc/profile.d/podman-rootless-policy.sh <<'EOF_PROFILE'
# Qubes dev-containers policy:
# - Use rootless Podman only.
# - Host networking and host namespaces are blocked by /usr/local/bin/podman.
# - Rootless slirp4netns is forced with allow_host_loopback=false.
export PATH="/usr/local/bin:$PATH"
alias podman-run-safe='podman run'
EOF_PROFILE
chmod 0644 /etc/profile.d/podman-rootless-policy.sh
chown root:root /etc/profile.d/podman-rootless-policy.sh

# Reduce accidental daemon/rootful container exposure.
systemctl --global disable podman.socket podman.service 2>/dev/null || true
systemctl disable podman.socket podman.service 2>/dev/null || true
systemctl mask podman.socket podman.service 2>/dev/null || true
systemctl disable docker.socket docker.service containerd.service 2>/dev/null || true
systemctl mask docker.socket docker.service containerd.service 2>/dev/null || true

# Ensure the default user has subordinate ID ranges for rootless user namespaces.
default_user="${SUDO_USER:-user}"
if id "$default_user" >/dev/null 2>&1; then
  grep -q "^${default_user}:" /etc/subuid 2>/dev/null || echo "${default_user}:100000:65536" >> /etc/subuid
  grep -q "^${default_user}:" /etc/subgid 2>/dev/null || echo "${default_user}:100000:65536" >> /etc/subgid
fi

cat > /home/user/QubesNotes/CONTAINER-POLICY.txt <<'EOF_POLICY'
Container policy inherited by the dev-containers named DisposableVM:

- Use podman as the normal user, not sudo/root.
- /usr/local/bin/podman refuses rootful execution.
- podman run/create automatically adds:
    --user <your uid>:<your gid>
    --userns=keep-id
    --security-opt=no-new-privileges
    --cap-drop=all
    --network=slirp4netns:allow_host_loopback=false
- Host network, host PID/IPC/UTS/user namespaces, --privileged, --cap-add, and --device are blocked.
- Containers cannot use host loopback through slirp4netns.
- Container-local 127.0.0.1 and ::1 still exist inside the container namespace; that is normal.

Test:
  podman info
  podman run --rm alpine id
EOF_POLICY
chown user:user /home/user/QubesNotes/CONTAINER-POLICY.txt 2>/dev/null || true
EOF_GUARD_INSTALL

  qvm-run -u root -p "$vm" "chmod 0755 /usr/local/sbin/install-rootless-container-guard.sh && /usr/local/sbin/install-rootless-container-guard.sh" || true
}


install_adguard_container() {
  local vm="adguard-dns"

  log "Installing rootless AdGuard Home container inside ${vm}..."

  qvm-prefs "$vm" provides_network True || true
  qvm-prefs "$vm" netvm "suricata-ips"

  # Let most app qubes route through adguard-dns. work-aws routes through aws-openvpn.
  for downstream in work-gmail work-github ssh-admin dev-containers untrusted; do
    qvm-prefs "$downstream" netvm "$vm" || true
  done

  # Basic outbound firewall for the AdGuard qube itself.
  qvm-firewall "$vm" reset || true
  qvm-firewall "$vm" add accept proto=tcp dstports=80,443 || true
  qvm-firewall "$vm" add accept proto=udp dstports=53 || true
  qvm-firewall "$vm" add accept proto=tcp dstports=53 || true
  qvm-firewall "$vm" add drop || true

  qvm-run -u root -p "$vm" 'cat > /usr/local/sbin/install-adguard-rootless.sh' <<'EOF_ADGUARD_INSTALL'
#!/usr/bin/env bash
set -euo pipefail

real_podman=""
for candidate in /usr/bin/podman /bin/podman; do
  if [[ -x "$candidate" ]]; then
    real_podman="$candidate"
    break
  fi
done

if [[ -z "$real_podman" ]]; then
  cat >&2 <<'EOF'
Podman is not installed yet.

Install Podman in the TemplateVM, not dom0. Fedora template example:
  sudo dnf install -y podman slirp4netns fuse-overlayfs shadow-utils iptables iproute

Then rerun this dom0 script.
EOF
  exit 0
fi

install -d -o user -g user -m 0700 /home/user/adguard/conf
install -d -o user -g user -m 0700 /home/user/adguard/work
install -d -o user -g user -m 0700 /home/user/.config/containers/systemd
install -d -o root -g root -m 0755 /rw/config
install -d -o user -g user -m 0755 /home/user/QubesNotes

cat > /home/user/adguard/conf/AdGuardHome.yaml <<'EOF_ADGUARD_YAML'
bind_host: 0.0.0.0
bind_port: 3000
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto

dns:
  bind_hosts:
    - 0.0.0.0
    - "::"
  # Non-root container listens on high port. Qubes firewall script redirects
  # downstream VM DNS/53 traffic to host port 5353.
  port: 5353
  anonymize_client_ip: true
  ratelimit: 15
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    # Local cloudflared DoH proxy running in the same rootless pod.
    # This is DNS-only; it is not a full WARP tunnel.
    - 127.0.0.1:5053
    - https://security.cloudflare-dns.com/dns-query
    - https://dns.quad9.net/dns-query
  bootstrap_dns:
    - 1.1.1.2
    - 1.0.0.2
    - 9.9.9.9
    - 149.112.112.112
  fallback_dns: []
  upstream_mode: parallel
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  cache_size: 4194304
  cache_ttl_min: 300
  cache_ttl_max: 3600
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: true
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []

filtering:
  protection_enabled: true
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: true
  safebrowsing_cache_size: 1048576
  safebrowsing_cache_ttl: 30
  filters_update_interval: 12
  blocking_mode: default
  blocked_response_ttl: 10
  protection_disabled_until: null
  safe_search:
    enabled: false
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  filters:
    - enabled: true
      url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
      name: AdGuard DNS filter
      id: 1
    - enabled: true
      url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt
      name: HaGeZi Multi Pro
      id: 2
    - enabled: true
      url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt
      name: HaGeZi Threat Intelligence Feed
      id: 3
    - enabled: true
      url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/fake.txt
      name: HaGeZi Fake and Scam Protection
      id: 4
    - enabled: true
      url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/doh-vpn-proxy-bypass.txt
      name: HaGeZi DoH VPN Proxy Bypass
      id: 5
    - enabled: true
      url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.winoffice.txt
      name: HaGeZi Native Windows Office Tracker
      id: 6
    - enabled: true
      url: https://phishing.army/download/phishing_army_blocklist_extended.txt
      name: Phishing Army Extended
      id: 7
    - enabled: true
      url: https://urlhaus.abuse.ch/downloads/hostfile/
      name: URLhaus Malware and Botnet Hosts
      id: 8
  user_rules:
    # Common allow rules to reduce breakage for daily work.
    - "@@||accounts.google.com^"
    - "@@||mail.google.com^"
    - "@@||github.com^"
    - "@@||githubusercontent.com^"
    - "@@||amazonaws.com^"
    - "@@||aws.amazon.com^"
    # Defensive local/rebind style blocking.
    - "||localhost^$important"
    - "||localdomain^$important"
    - "||0.0.0.0^$important"
    - "||127.0.0.1^$important"
    - "||::1^$important"

querylog:
  # Disable persistent query logging to reduce frequency/pattern leakage.
  enabled: false
  file_enabled: false
  interval: 1h
  size_memory: 1000
  ignored: []

statistics:
  # Disable persistent statistics to reduce local profiling of browsing frequency.
  enabled: false
  interval: 24h
  ignored: []

tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false

os:
  group: ""
  user: ""
  rlimit_nofile: 0

schema_version: 29
EOF_ADGUARD_YAML

chown -R user:user /home/user/adguard
chmod 0600 /home/user/adguard/conf/AdGuardHome.yaml

cat > /home/user/.config/containers/systemd/adguard-stack.pod <<'EOF_POD'
[Unit]
Description=Rootless AdGuard DNS stack pod
After=network-online.target
Wants=network-online.target

[Pod]
PodName=adguard-stack
PublishPort=5353:5353/udp
PublishPort=5353:5353/tcp
PublishPort=3000:3000/tcp
Network=slirp4netns:allow_host_loopback=false

[Install]
WantedBy=default.target
EOF_POD

cat > /home/user/.config/containers/systemd/cloudflared-dns.container <<'EOF_CLOUDFLARED'
[Unit]
Description=Rootless cloudflared DNS-over-HTTPS proxy for AdGuard
After=adguard-stack-pod.service
Requires=adguard-stack-pod.service

[Container]
Image=docker.io/cloudflare/cloudflared:latest
ContainerName=cloudflared-dns
Pod=adguard-stack.pod
UserNS=keep-id
User=1000:1000
Exec=proxy-dns --address 127.0.0.1 --port 5053 --upstream https://security.cloudflare-dns.com/dns-query --upstream https://1.1.1.1/dns-query
AddCapability=
DropCapability=all
NoNewPrivileges=true
ReadOnly=true
Tmpfs=/tmp

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF_CLOUDFLARED

cat > /home/user/.config/containers/systemd/adguard-home.container <<'EOF_QUADLET'
[Unit]
Description=Rootless AdGuard Home DNS filtering container
After=adguard-stack-pod.service cloudflared-dns.service
Requires=adguard-stack-pod.service cloudflared-dns.service

[Container]
Image=docker.io/adguard/adguardhome:latest
ContainerName=adguard-home
Pod=adguard-stack.pod
UserNS=keep-id
User=1000:1000
Volume=/home/user/adguard/conf:/opt/adguardhome/conf:Z
Tmpfs=/opt/adguardhome/work
AddCapability=
DropCapability=all
NoNewPrivileges=true
ReadOnly=true
Tmpfs=/tmp
SecurityLabelDisable=false

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF_QUADLET

chown user:user /home/user/.config/containers/systemd/adguard-stack.pod \
  /home/user/.config/containers/systemd/cloudflared-dns.container \
  /home/user/.config/containers/systemd/adguard-home.container
chmod 0644 /home/user/.config/containers/systemd/adguard-stack.pod \
  /home/user/.config/containers/systemd/cloudflared-dns.container \
  /home/user/.config/containers/systemd/adguard-home.container

# Redirect downstream qube DNS/53 to the rootless AdGuard container high port.
# The container itself remains non-root and cannot access host loopback.
cat > /rw/config/qubes-firewall-user-script <<'EOF_QUBES_FW'
#!/bin/sh
# Route DNS from downstream qubes through rootless AdGuard Home.
# AdGuard listens on host port 5353; downstream qubes still use normal DNS/53.
# Do not expose AdGuard admin UI outside this qube.

# IPv4
iptables -t nat -C PREROUTING -i vif+ -p udp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
  iptables -t nat -I PREROUTING -i vif+ -p udp --dport 53 -j REDIRECT --to-ports 5353
iptables -t nat -C PREROUTING -i vif+ -p tcp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
  iptables -t nat -I PREROUTING -i vif+ -p tcp --dport 53 -j REDIRECT --to-ports 5353

# Block downstream access to AdGuard admin UI by default.
iptables -C INPUT -i vif+ -p tcp --dport 3000 -j DROP 2>/dev/null || \
  iptables -I INPUT -i vif+ -p tcp --dport 3000 -j DROP

# IPv6, if available.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t nat -C PREROUTING -i vif+ -p udp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
    ip6tables -t nat -I PREROUTING -i vif+ -p udp --dport 53 -j REDIRECT --to-ports 5353 || true
  ip6tables -t nat -C PREROUTING -i vif+ -p tcp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
    ip6tables -t nat -I PREROUTING -i vif+ -p tcp --dport 53 -j REDIRECT --to-ports 5353 || true
  ip6tables -C INPUT -i vif+ -p tcp --dport 3000 -j DROP 2>/dev/null || \
    ip6tables -I INPUT -i vif+ -p tcp --dport 3000 -j DROP || true
fi
EOF_QUBES_FW
chmod 0755 /rw/config/qubes-firewall-user-script
chown root:root /rw/config/qubes-firewall-user-script

cat > /home/user/QubesNotes/ADGUARD-POLICY.txt <<'EOF_ADGUARD_POLICY'
AdGuard Home policy in this qube:

- AdGuard and cloudflared run rootless as user 1000:1000.
- Containers are read-only with tmpfs /tmp.
- Containers drop all capabilities.
- NoNewPrivileges=true.
- slirp4netns uses allow_host_loopback=false.
- cloudflared provides DNS-over-HTTPS on 127.0.0.1:5053 inside the pod.
- AdGuard DNS listens on high port 5353 inside and outside the pod.
- AdGuard work/state directory is tmpfs, so container runtime state resets on boot.
- Qubes firewall redirects downstream qube DNS port 53 to 5353.
- Downstream qubes should use this qube as NetVM.
- AdGuard admin UI is on port 3000 but blocked from downstream qubes.
- Query logging and statistics are disabled to reduce frequency/pattern leakage.
- DNS rate limit is enabled.
- ANY queries are refused.
- DNSSEC is enabled.
- Upstreams use DoH security resolvers.

Blocklist intent:
- AdGuard DNS filter: baseline ads/tracking.
- HaGeZi Multi Pro: broad tracking/ad/malware blocklist.
- HaGeZi TIF: malware, phishing, scam, spam threat intelligence.
- HaGeZi Fake: fake/scam/phishing-style protection.
- HaGeZi DoH/VPN/Proxy Bypass: reduce DNS bypass channels.
- HaGeZi Native Windows Office Tracker: native telemetry domains.
- Phishing Army Extended: phishing domains.
- URLhaus: malware/botnet distribution hosts.

Test:
  systemctl --user status adguard-stack-pod cloudflared-dns adguard-home
  podman ps
  dig @127.0.0.1 -p 5353 example.com
EOF_ADGUARD_POLICY
chown user:user /home/user/QubesNotes/ADGUARD-POLICY.txt

# Enable lingering so the rootless user service starts without an interactive login.
loginctl enable-linger user || true

# Start rootless Quadlet service.
runuser -l user -c 'systemctl --user daemon-reload'
runuser -l user -c 'systemctl --user enable --now adguard-stack-pod.service cloudflared-dns.service adguard-home.service'

# Apply DNS redirect rules now if this qube is already acting as a ProxyVM.
sh /rw/config/qubes-firewall-user-script || true
EOF_ADGUARD_INSTALL

  qvm-run -u root -p "$vm" "chmod 0755 /usr/local/sbin/install-adguard-rootless.sh && /usr/local/sbin/install-adguard-rootless.sh" || true
}


install_aws_openvpn_container() {
  local vm="aws-openvpn"

  log "Preparing dedicated AWS OpenVPN ProxyVM: ${vm}"

  qvm-prefs "$vm" provides_network True || true
  qvm-prefs "$vm" netvm "adguard-dns"

  # Route only AWS work through the AWS OpenVPN qube.
  qvm-prefs work-aws netvm "$vm" || true

  # Permit the VPN qube to reach common OpenVPN endpoints and DNS during tunnel setup.
  # Tighten this after you know your VPN server IP/protocol/port.
  qvm-firewall "$vm" reset || true
  qvm-firewall "$vm" add accept proto=udp dstports=1194 || true
  qvm-firewall "$vm" add accept proto=tcp dstports=443 || true
  qvm-firewall "$vm" add accept proto=udp dstports=53 || true
  qvm-firewall "$vm" add accept proto=tcp dstports=53 || true
  qvm-firewall "$vm" add drop || true

  qvm-run -u root -p "$vm" 'cat > /usr/local/sbin/install-aws-openvpn-container.sh' <<'EOF_AWS_OVPN_INSTALL'
#!/usr/bin/env bash
set -euo pipefail

real_podman=""
for candidate in /usr/bin/podman /bin/podman; do
  if [[ -x "$candidate" ]]; then
    real_podman="$candidate"
    break
  fi
done

if [[ -z "$real_podman" ]]; then
  cat >&2 <<'EOF'
Podman is not installed yet.

Install Podman in the TemplateVM, not dom0. Fedora template example:
  sudo dnf install -y podman iptables iproute

Then rerun the dom0 bootstrap.
EOF
  exit 0
fi

install -d -o root -g root -m 0700 /rw/config/openvpn/aws
install -d -o root -g root -m 0755 /usr/local/sbin
install -d -o root -g root -m 0755 /etc/containers/systemd
install -d -o root -g root -m 0755 /rw/config
install -d -o user -g user -m 0755 /home/user/QubesNotes

cat > /usr/local/sbin/import-aws-openvpn-config <<'EOF_IMPORT'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo import-aws-openvpn-config /path/to/client.ovpn [auth-user-pass-file]

What it does:
  - Copies the OpenVPN profile to /rw/config/openvpn/aws/client.ovpn
  - Optionally copies an auth-user-pass file to /rw/config/openvpn/aws/auth.txt
  - Locks permissions to root:root 0600
  - Rebuilds and restarts the aws-openvpn container service

Notes:
  - If your .ovpn references external cert/key files, inline them first or copy
    them into /rw/config/openvpn/aws and update client.ovpn paths.
  - This qube is a dedicated exception: OpenVPN needs NET_ADMIN and /dev/net/tun.
EOF_USAGE
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }

src_ovpn="$1"
src_auth="${2:-}"

[[ -f "$src_ovpn" ]] || { echo "Missing ovpn file: $src_ovpn" >&2; exit 1; }

install -d -o root -g root -m 0700 /rw/config/openvpn/aws
install -o root -g root -m 0600 "$src_ovpn" /rw/config/openvpn/aws/client.ovpn

if [[ -n "$src_auth" ]]; then
  [[ -f "$src_auth" ]] || { echo "Missing auth file: $src_auth" >&2; exit 1; }
  install -o root -g root -m 0600 "$src_auth" /rw/config/openvpn/aws/auth.txt
  if ! grep -Eq '^[[:space:]]*auth-user-pass[[:space:]]+/vpn/auth.txt' /rw/config/openvpn/aws/client.ovpn; then
    if grep -Eq '^[[:space:]]*auth-user-pass' /rw/config/openvpn/aws/client.ovpn; then
      sed -i 's|^[[:space:]]*auth-user-pass.*|auth-user-pass /vpn/auth.txt|' /rw/config/openvpn/aws/client.ovpn
    else
      printf '\nauth-user-pass /vpn/auth.txt\n' >> /rw/config/openvpn/aws/client.ovpn
    fi
  fi
fi

# Safer OpenVPN client defaults if absent.
grep -Eq '^[[:space:]]*auth-nocache' /rw/config/openvpn/aws/client.ovpn || printf '\nauth-nocache\n' >> /rw/config/openvpn/aws/client.ovpn
grep -Eq '^[[:space:]]*pull-filter[[:space:]]+ignore[[:space:]]+"block-outside-dns"' /rw/config/openvpn/aws/client.ovpn || printf 'pull-filter ignore "block-outside-dns"\n' >> /rw/config/openvpn/aws/client.ovpn

systemctl daemon-reload
systemctl restart aws-openvpn.service || true

echo "Imported /rw/config/openvpn/aws/client.ovpn."
echo "Check status with: sudo systemctl status aws-openvpn"
EOF_IMPORT
chmod 0755 /usr/local/sbin/import-aws-openvpn-config
chown root:root /usr/local/sbin/import-aws-openvpn-config

cat > /rw/config/openvpn/aws/Containerfile <<'EOF_CONTAINERFILE'
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache openvpn iptables ip6tables iproute2 ca-certificates bash tini
ENTRYPOINT ["/sbin/tini", "--", "/usr/sbin/openvpn"]
CMD ["--config", "/vpn/client.ovpn"]
EOF_CONTAINERFILE
chmod 0600 /rw/config/openvpn/aws/Containerfile
chown root:root /rw/config/openvpn/aws/Containerfile

cat > /usr/local/sbin/build-aws-openvpn-image <<'EOF_BUILD'
#!/usr/bin/env bash
set -euo pipefail
podman build -t localhost/aws-openvpn-client:latest -f /rw/config/openvpn/aws/Containerfile /rw/config/openvpn/aws
EOF_BUILD
chmod 0755 /usr/local/sbin/build-aws-openvpn-image
chown root:root /usr/local/sbin/build-aws-openvpn-image

cat > /etc/containers/systemd/aws-openvpn.container <<'EOF_QUADLET'
[Unit]
Description=AWS OpenVPN client container for Qubes ProxyVM
After=network-online.target
Wants=network-online.target
ConditionPathExists=/rw/config/openvpn/aws/client.ovpn

[Container]
Image=localhost/aws-openvpn-client:latest
ContainerName=aws-openvpn
Network=host
AddCapability=NET_ADMIN
Device=/dev/net/tun
Volume=/rw/config/openvpn/aws:/vpn:ro
ReadOnly=true
Tmpfs=/tmp
NoNewPrivileges=false
SecurityLabelDisable=false

[Service]
Restart=always
RestartSec=10
ExecStartPre=/usr/local/sbin/build-aws-openvpn-image

[Install]
WantedBy=multi-user.target
EOF_QUADLET
chmod 0644 /etc/containers/systemd/aws-openvpn.container
chown root:root /etc/containers/systemd/aws-openvpn.container

cat > /rw/config/qubes-firewall-user-script <<'EOF_FW'
#!/bin/sh
# Qubes ProxyVM firewall rules for AWS OpenVPN.
# The OpenVPN container uses host networking, so tun0 appears in this qube namespace.

# NAT downstream qubes through OpenVPN tunnel.
iptables -t nat -C POSTROUTING -o tun+ -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o tun+ -j MASQUERADE

iptables -C FORWARD -i vif+ -o tun+ -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD -i vif+ -o tun+ -j ACCEPT

iptables -C FORWARD -i tun+ -o vif+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD -i tun+ -o vif+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Kill switch: once traffic is from downstream qubes, do not let it bypass tun+.
iptables -C FORWARD -i vif+ ! -o tun+ -j REJECT 2>/dev/null || \
  iptables -A FORWARD -i vif+ ! -o tun+ -j REJECT
EOF_FW
chmod 0755 /rw/config/qubes-firewall-user-script
chown root:root /rw/config/qubes-firewall-user-script

cat > /home/user/QubesNotes/AWS-OPENVPN.txt <<'EOF_NOTE'
AWS OpenVPN qube:

This qube is a dedicated exception to the strict rootless container policy.
OpenVPN must create/manage a TUN interface and routes, so it uses:
  - Network=host inside this dedicated qube
  - /dev/net/tun
  - CAP_NET_ADMIN

This exception is isolated to aws-openvpn only.
Do not browse the web or store general secrets in this qube.

Import a config:
  1. Copy your AWS/client OpenVPN profile into this qube.
  2. Run:
       sudo import-aws-openvpn-config ~/client.ovpn
     Or, with username/password file:
       sudo import-aws-openvpn-config ~/client.ovpn ~/auth.txt

Status:
  sudo systemctl status aws-openvpn
  sudo journalctl -u aws-openvpn -f
  ip addr show tun0

Routing:
  work-aws is configured to use aws-openvpn as its NetVM.
EOF_NOTE
chown user:user /home/user/QubesNotes/AWS-OPENVPN.txt

systemctl daemon-reload

if [[ -f /rw/config/openvpn/aws/client.ovpn ]]; then
  systemctl enable --now aws-openvpn.service || true
else
  systemctl enable aws-openvpn.service || true
  echo "No /rw/config/openvpn/aws/client.ovpn yet. Use sudo import-aws-openvpn-config."
fi
EOF_AWS_OVPN_INSTALL

  qvm-run -u root -p "$vm" "chmod 0755 /usr/local/sbin/install-aws-openvpn-container.sh && /usr/local/sbin/install-aws-openvpn-container.sh" || true
}


install_suricata_ips_container() {
  local vm="suricata-ips"

  log "Preparing dedicated Suricata IDS/IPS ProxyVM: ${vm}"

  qvm-prefs "$vm" provides_network True || true
  qvm-prefs "$vm" netvm "$NETVM"

  # Permit the Suricata qube itself to update rules and resolve DNS.
  qvm-firewall "$vm" reset || true
  qvm-firewall "$vm" add accept proto=tcp dstports=80,443 || true
  qvm-firewall "$vm" add accept proto=udp dstports=53 || true
  qvm-firewall "$vm" add accept proto=tcp dstports=53 || true
  qvm-firewall "$vm" add drop || true

  qvm-run -u root -p "$vm" 'cat > /usr/local/sbin/install-suricata-ips-container.sh' <<'EOF_SURICATA_INSTALL'
#!/usr/bin/env bash
set -euo pipefail

real_podman=""
for candidate in /usr/bin/podman /bin/podman; do
  if [[ -x "$candidate" ]]; then
    real_podman="$candidate"
    break
  fi
done

if [[ -z "$real_podman" ]]; then
  cat >&2 <<'EOF'
Podman is not installed yet.

Install Podman and firewall tools in the TemplateVM, not dom0. Fedora example:
  sudo dnf install -y podman iptables iproute curl tar gzip

Then rerun the dom0 bootstrap.
EOF
  exit 0
fi

install -d -o root -g root -m 0755 /usr/local/sbin
install -d -o root -g root -m 0755 /etc/containers/systemd
install -d -o root -g root -m 0755 /rw/config/suricata/rules
install -d -o root -g root -m 0755 /rw/config/suricata/config
install -d -o root -g root -m 0755 /rw/config
install -d -o user -g user -m 0755 /home/user/QubesNotes

cat > /rw/config/suricata/rules/local.rules <<'EOF_LOCAL_RULES'
# Local high-signal rules. Start conservative; tune before broad blocking.
alert ip any any -> any any (msg:"QUBES-SURICATA visibility baseline"; sid:9000001; rev:1;)
alert dns any any -> any any (msg:"QUBES-SURICATA DNS traffic observed"; sid:9000002; rev:1;)
drop ip any any -> 0.0.0.0/8 any (msg:"QUBES-SURICATA drop invalid 0.0.0.0/8 destination"; sid:9000010; rev:1;)
drop ip any any -> 127.0.0.0/8 any (msg:"QUBES-SURICATA drop loopback destination from routed traffic"; sid:9000011; rev:1;)
drop ip any any -> 169.254.0.0/16 any (msg:"QUBES-SURICATA drop link-local destination from routed traffic"; sid:9000012; rev:1;)
drop ip any any -> 224.0.0.0/4 any (msg:"QUBES-SURICATA drop multicast destination from routed traffic"; sid:9000013; rev:1;)
EOF_LOCAL_RULES

cat > /rw/config/suricata/config/suricata.yaml <<'EOF_SURICATA_YAML'
%YAML 1.1
---
vars:
  address-groups:
    HOME_NET: "[10.137.0.0/16]"
    EXTERNAL_NET: "!$HOME_NET"
  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22

default-log-dir: /var/log/suricata
stats:
  enabled: yes
  interval: 60

outputs:
  - fast:
      enabled: yes
      filename: fast.log
      append: no
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      community-id: true
      types:
        - alert
        - anomaly
        - dns
        - http
        - tls
        - flow

logging:
  default-log-level: notice

af-packet: []

nfq:
  mode: accept
  repeat-mark: 1
  repeat-mask: 1
  route-queue: 0
  batchcount: 20
  fail-open: no

default-rule-path: /etc/suricata/rules
rule-files:
  - local.rules

classification-file: /etc/suricata/classification.config
reference-config-file: /etc/suricata/reference.config

app-layer:
  protocols:
    tls:
      enabled: yes
    http:
      enabled: yes
    dns:
      udp:
        enabled: yes
      tcp:
        enabled: yes
EOF_SURICATA_YAML

cat > /rw/config/suricata/Containerfile <<'EOF_CONTAINERFILE'
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache suricata iptables ip6tables iproute2 ca-certificates bash tini
COPY config/suricata.yaml /etc/suricata/suricata.yaml
COPY rules/local.rules /etc/suricata/rules/local.rules
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/bin/suricata", "-q", "0", "-k", "none", "-c", "/etc/suricata/suricata.yaml"]
EOF_CONTAINERFILE

cat > /usr/local/sbin/build-suricata-ips-image <<'EOF_BUILD'
#!/usr/bin/env bash
set -euo pipefail
podman build -t localhost/qubes-suricata-ips:latest -f /rw/config/suricata/Containerfile /rw/config/suricata
EOF_BUILD
chmod 0755 /usr/local/sbin/build-suricata-ips-image
chown root:root /usr/local/sbin/build-suricata-ips-image

cat > /etc/containers/systemd/suricata-ips.container <<'EOF_QUADLET'
[Unit]
Description=Suricata IDS/IPS container for Qubes ProxyVM
After=network-online.target
Wants=network-online.target

[Container]
Image=localhost/qubes-suricata-ips:latest
ContainerName=suricata-ips
Network=host
AddCapability=NET_ADMIN
AddCapability=NET_RAW
ReadOnly=true
Tmpfs=/tmp
Tmpfs=/var/log/suricata
NoNewPrivileges=false
SecurityLabelDisable=false

[Service]
Restart=always
RestartSec=10
ExecStartPre=/usr/local/sbin/build-suricata-ips-image

[Install]
WantedBy=multi-user.target
EOF_QUADLET
chmod 0644 /etc/containers/systemd/suricata-ips.container
chown root:root /etc/containers/systemd/suricata-ips.container

cat > /rw/config/qubes-firewall-user-script <<'EOF_FW'
#!/bin/sh
# Qubes ProxyVM firewall rules for Suricata IPS.
# Downstream qube traffic entering via vif+ is sent to NFQUEUE 0.
# This is fail-closed by default when Suricata/NFQUEUE is not available.

modprobe nfnetlink_queue 2>/dev/null || true

iptables -C FORWARD -i vif+ -j NFQUEUE --queue-num 0 2>/dev/null || \
  iptables -I FORWARD 1 -i vif+ -j NFQUEUE --queue-num 0

iptables -C FORWARD -i vif+ -o eth0 -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i vif+ -o eth0 -j ACCEPT

iptables -C FORWARD -i eth0 -o vif+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i eth0 -o vif+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF_FW
chmod 0755 /rw/config/qubes-firewall-user-script
chown root:root /rw/config/qubes-firewall-user-script

cat > /home/user/QubesNotes/SURICATA-IPS.txt <<'EOF_NOTE'
Suricata IDS/IPS qube:

This is a dedicated ProxyVM exception because inline IDS/IPS needs privileged
packet inspection:
  - Network=host inside this dedicated qube
  - CAP_NET_ADMIN
  - CAP_NET_RAW
  - NFQUEUE forwarding rules in /rw/config/qubes-firewall-user-script

This exception is isolated to suricata-ips only.

Fresh-slate behavior:
  - Suricata logs are tmpfs and reset on qube reboot.
  - The container is read-only.
  - Rules/config are generated under /rw/config/suricata and can be replaced
    by rerunning qubes-dom0-bootstrap.sh.

Status:
  sudo systemctl status suricata-ips
  sudo journalctl -u suricata-ips -f
  sudo iptables -S FORWARD
  sudo iptables -t nat -S
EOF_NOTE
chown user:user /home/user/QubesNotes/SURICATA-IPS.txt

systemctl daemon-reload
systemctl enable --now suricata-ips.service || true
sh /rw/config/qubes-firewall-user-script || true
EOF_SURICATA_INSTALL

  qvm-run -u root -p "$vm" "chmod 0755 /usr/local/sbin/install-suricata-ips-container.sh && /usr/local/sbin/install-suricata-ips-container.sh" || true
}


install_caddy_web_container() {
  local vm="caddy-web"

  log "Installing rootless Caddy reverse proxy container inside ${vm}..."

  qvm-prefs "$vm" netvm "adguard-dns" || true

  qvm-firewall "$vm" reset || true
  qvm-firewall "$vm" add accept proto=tcp dstports=80,443,8080,8443 || true
  qvm-firewall "$vm" add accept proto=udp dstports=53 || true
  qvm-firewall "$vm" add drop || true

  qvm-run -u root -p "$vm" 'cat > /usr/local/sbin/install-caddy-rootless.sh' <<'EOF_CADDY_INSTALL'
#!/usr/bin/env bash
set -euo pipefail

real_podman=""
for candidate in /usr/bin/podman /bin/podman; do
  if [[ -x "$candidate" ]]; then
    real_podman="$candidate"
    break
  fi
done

if [[ -z "$real_podman" ]]; then
  cat >&2 <<'EOF'
Podman is not installed yet.

Install Podman in the TemplateVM, not dom0. Fedora template example:
  sudo dnf install -y podman slirp4netns fuse-overlayfs shadow-utils

Then rerun the dom0 bootstrap.
EOF
  exit 0
fi

install -d -o user -g user -m 0700 /home/user/caddy/config
install -d -o user -g user -m 0700 /home/user/caddy/site
install -d -o user -g user -m 0700 /home/user/.config/containers/systemd
install -d -o user -g user -m 0755 /home/user/QubesNotes

cat > /home/user/caddy/site/index.html <<'EOF_INDEX'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Qubes Caddy Proxy</title>
</head>
<body>
  <h1>Qubes Caddy Proxy</h1>
  <p>This rootless Caddy container is running. Replace this static site or edit the reverse_proxy examples in Caddyfile.</p>
</body>
</html>
EOF_INDEX

cat > /home/user/caddy/config/Caddyfile <<'EOF_CADDYFILE'
{
	admin off
	auto_https off
}

:8080 {
	root * /srv
	file_server

	header {
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		X-XSS-Protection "0"
		Referrer-Policy "no-referrer"
		Permissions-Policy "accelerometer=(), ambient-light-sensor=(), autoplay=(), battery=(), camera=(), display-capture=(), document-domain=(), encrypted-media=(), fullscreen=(), geolocation=(), gyroscope=(), interest-cohort=(), magnetometer=(), microphone=(), midi=(), payment=(), publickey-credentials-get=(), screen-wake-lock=(), serial=(), sync-xhr=(), usb=(), xr-spatial-tracking=()"
		Cross-Origin-Opener-Policy "same-origin"
		Cross-Origin-Resource-Policy "same-origin"
		Origin-Agent-Cluster "?1"
		Content-Security-Policy "default-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; img-src 'self' data:; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; upgrade-insecure-requests"
		-Server
	}

	# Example reverse proxy. Uncomment and edit the upstream.
	# reverse_proxy http://10.137.X.Y:PORT
}

# HTTPS/internal example. Provide certs as:
#   /config/certs/fullchain.pem
#   /config/certs/privkey.pem
#
# :8443 {
# 	tls /config/certs/fullchain.pem /config/certs/privkey.pem
# 	reverse_proxy http://10.137.X.Y:PORT
# 	header {
# 		Strict-Transport-Security "max-age=63072000; includeSubDomains"
# 		X-Content-Type-Options "nosniff"
# 		X-Frame-Options "DENY"
# 		X-XSS-Protection "0"
# 		Referrer-Policy "no-referrer"
# 		Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), microphone=(), payment=(), usb=()"
# 		Cross-Origin-Opener-Policy "same-origin"
# 		Cross-Origin-Resource-Policy "same-origin"
# 		Origin-Agent-Cluster "?1"
# 		Content-Security-Policy "default-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; img-src 'self' data:; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; upgrade-insecure-requests"
# 		-Server
# 	}
# }
EOF_CADDYFILE

chown -R user:user /home/user/caddy
chmod 0600 /home/user/caddy/config/Caddyfile

cat > /home/user/.config/containers/systemd/caddy-web.container <<'EOF_QUADLET'
[Unit]
Description=Rootless Caddy reverse proxy with security headers
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/library/caddy:2-alpine
ContainerName=caddy-web
UserNS=keep-id
User=1000:1000
Volume=/home/user/caddy/config/Caddyfile:/etc/caddy/Caddyfile:ro,Z
Volume=/home/user/caddy/site:/srv:ro,Z
PublishPort=8080:8080/tcp
PublishPort=8443:8443/tcp
Network=slirp4netns:allow_host_loopback=false
AddCapability=
DropCapability=all
NoNewPrivileges=true
ReadOnly=true
Tmpfs=/tmp
Tmpfs=/data
Tmpfs=/config
SecurityLabelDisable=false

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF_QUADLET

chown user:user /home/user/.config/containers/systemd/caddy-web.container
chmod 0644 /home/user/.config/containers/systemd/caddy-web.container

cat > /home/user/QubesNotes/CADDY-WEB.txt <<'EOF_NOTE'
Caddy web/reverse proxy qube:

Container policy:
- rootless container as user 1000:1000
- no added capabilities
- drops all capabilities
- NoNewPrivileges=true
- read-only container root
- tmpfs for /tmp, /data, and /config
- slirp4netns with allow_host_loopback=false
- high ports only: 8080 and 8443

Config:
- Caddyfile: /home/user/caddy/config/Caddyfile
- Static site root: /home/user/caddy/site
- Container unit: /home/user/.config/containers/systemd/caddy-web.container

Default security headers:
- X-Content-Type-Options: nosniff
- X-Frame-Options: DENY
- Referrer-Policy: no-referrer
- Permissions-Policy: restrictive browser APIs
- Cross-Origin-Opener-Policy: same-origin
- Cross-Origin-Resource-Policy: same-origin
- Origin-Agent-Cluster: ?1
- Content-Security-Policy: conservative static baseline
- Server header removed

HSTS:
- HSTS is commented out for HTTP.
- Enable HSTS only on HTTPS :8443 with an actual certificate.

Status:
  systemctl --user status caddy-web
  podman ps
  curl -I http://127.0.0.1:8080

Edit config:
  nano /home/user/caddy/config/Caddyfile
  systemctl --user restart caddy-web
EOF_NOTE
chown user:user /home/user/QubesNotes/CADDY-WEB.txt

loginctl enable-linger user || true
runuser -l user -c 'systemctl --user daemon-reload'
runuser -l user -c 'systemctl --user enable --now caddy-web.service'
EOF_CADDY_INSTALL

  qvm-run -u root -p "$vm" "chmod 0755 /usr/local/sbin/install-caddy-rootless.sh && /usr/local/sbin/install-caddy-rootless.sh" || true
}


install_portainer_mgmt_container() {
  local vm="portainer-mgmt"

  log "Installing rootless Portainer management container inside ${vm}..."
  qvm-prefs "$vm" netvm "adguard-dns" || true

  qvm-firewall "$vm" reset || true
  qvm-firewall "$vm" add accept proto=tcp dstports=80,443,9443 || true
  qvm-firewall "$vm" add accept proto=udp dstports=53 || true
  qvm-firewall "$vm" add drop || true

  qvm-run -u root -p "$vm" 'cat > /usr/local/sbin/install-portainer-rootless.sh' <<'EOF_PORTAINER_INSTALL'
#!/usr/bin/env bash
set -euo pipefail

real_podman=""
for candidate in /usr/bin/podman /bin/podman; do
  if [[ -x "$candidate" ]]; then
    real_podman="$candidate"
    break
  fi
done

if [[ -z "$real_podman" ]]; then
  cat >&2 <<'EOF'
Podman is not installed yet.

Install Podman in the TemplateVM, not dom0. Fedora template example:
  sudo dnf install -y podman slirp4netns fuse-overlayfs shadow-utils

Then rerun the dom0 bootstrap.
EOF
  exit 0
fi

install -d -o user -g user -m 0700 /home/user/portainer/data
install -d -o user -g user -m 0700 /home/user/.config/containers/systemd
install -d -o user -g user -m 0755 /home/user/QubesNotes
install -d -o root -g root -m 0755 /usr/local/sbin

# Enable the rootless Podman API socket for the normal user.
# Portainer consumes this Docker-compatible socket as its local endpoint.
loginctl enable-linger user || true
runuser -l user -c 'systemctl --user enable --now podman.socket'

cat > /home/user/.config/containers/systemd/portainer-mgmt.container <<'EOF_QUADLET'
[Unit]
Description=Rootless Portainer CE for local Podman management
After=network-online.target podman.socket
Wants=network-online.target podman.socket

[Container]
Image=docker.io/portainer/portainer-ce:latest
ContainerName=portainer-mgmt
UserNS=keep-id
User=1000:1000
Volume=/run/user/1000/podman/podman.sock:/var/run/docker.sock:rw
Volume=/home/user/portainer/data:/data:Z
PublishPort=9443:9443/tcp
Network=slirp4netns:allow_host_loopback=false
AddCapability=
DropCapability=all
NoNewPrivileges=true
ReadOnly=true
Tmpfs=/tmp
SecurityLabelDisable=false
Exec=-H unix:///var/run/docker.sock --bind-https :9443

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF_QUADLET

chown user:user /home/user/.config/containers/systemd/portainer-mgmt.container
chmod 0644 /home/user/.config/containers/systemd/portainer-mgmt.container

cat > /usr/local/sbin/reset-portainer-mgmt <<'EOF_RESET'
#!/usr/bin/env bash
set -euo pipefail
echo "This will delete Portainer state in /home/user/portainer/data."
echo "Type RESET-PORTAINER to continue:"
read -r confirm
[[ "$confirm" == "RESET-PORTAINER" ]] || { echo "Cancelled."; exit 1; }
runuser -l user -c 'systemctl --user stop portainer-mgmt.service' || true
rm -rf /home/user/portainer/data
install -d -o user -g user -m 0700 /home/user/portainer/data
runuser -l user -c 'systemctl --user start portainer-mgmt.service'
echo "Portainer state reset. Open https://127.0.0.1:9443 inside portainer-mgmt."
EOF_RESET
chmod 0755 /usr/local/sbin/reset-portainer-mgmt
chown root:root /usr/local/sbin/reset-portainer-mgmt

cat > /usr/local/sbin/portainer-scope-warning <<'EOF_SCOPE'
#!/usr/bin/env bash
cat <<'EOF'
Portainer scope in this Qubes setup:

Default:
  Portainer manages the local rootless Podman endpoint in portainer-mgmt only.

Reason:
  Giving Portainer every qube's container socket would make portainer-mgmt a
  central control plane. If compromised, it could control all service qubes.

Recommended:
  Keep infrastructure containers managed by dom0 bootstrap scripts and Quadlets:
    adguard-dns
    aws-openvpn
    suricata-ips
    caddy-web

Use Portainer for:
  - experimenting with additional non-sensitive containers
  - viewing and managing containers/images inside portainer-mgmt
  - testing images before moving them into dedicated service qubes
EOF
EOF_SCOPE
chmod 0755 /usr/local/sbin/portainer-scope-warning
chown root:root /usr/local/sbin/portainer-scope-warning

cat > /home/user/QubesNotes/PORTAINER-MGMT.txt <<'EOF_NOTE'
Portainer management qube:

Default URL:
  https://127.0.0.1:9443

Status:
  systemctl --user status portainer-mgmt
  systemctl --user status podman.socket
  podman ps
  podman images

Security model:
- Portainer runs rootless.
- Portainer uses the local user Podman socket only:
    /run/user/1000/podman/podman.sock
- Container root is read-only.
- Runtime /tmp is tmpfs.
- No added Linux capabilities.
- All Linux capabilities dropped.
- NoNewPrivileges=true.
- slirp4netns uses allow_host_loopback=false.

Important:
- Portainer is a control plane.
- By default it manages only local containers inside portainer-mgmt.
- Do not expose every qube's Podman/Docker socket to Portainer unless you accept
  that compromise of portainer-mgmt could control those qubes.

Reset Portainer:
  sudo reset-portainer-mgmt

Scope warning:
  sudo portainer-scope-warning
EOF_NOTE
chown user:user /home/user/QubesNotes/PORTAINER-MGMT.txt

runuser -l user -c 'systemctl --user daemon-reload'
runuser -l user -c 'systemctl --user enable --now portainer-mgmt.service'
EOF_PORTAINER_INSTALL

  qvm-run -u root -p "$vm" "chmod 0755 /usr/local/sbin/install-portainer-rootless.sh && /usr/local/sbin/install-portainer-rootless.sh" || true
}

main() {
  require_dom0
  choose_template

  log "Using template: $TEMPLATE"
  log "Using network VM: $NETVM"

  create_appvm "vault" "black" "$OFFLINE_NETVM" 400 400 "10G"

  # Rebuildable network/service qubes. Chain:
  # app disposable -> adguard-dns -> suricata-ips -> sys-firewall
  # work-aws -> aws-openvpn -> adguard-dns -> suricata-ips -> sys-firewall
  create_appvm "suricata-ips" "red" "$NETVM" 1000 3000 "20G"
  create_appvm "adguard-dns" "orange" "suricata-ips" 800 2000 "15G"
  create_appvm "aws-openvpn" "purple" "adguard-dns" 800 2000 "10G"
  create_appvm "caddy-web" "green" "adguard-dns" 600 1500 "10G"
  create_appvm "portainer-mgmt" "blue" "adguard-dns" 800 2000 "10G"

  create_dvm_template "dvm-work-gmail" "green" "adguard-dns" 800 2000 "10G"
  create_dvm_template "dvm-work-github" "blue" "adguard-dns" 800 2500 "10G"
  create_dvm_template "dvm-work-aws" "orange" "aws-openvpn" 1000 3000 "10G"
  create_dvm_template "dvm-ssh-admin" "purple" "adguard-dns" 600 1200 "10G"
  create_dvm_template "dvm-dev-containers" "yellow" "adguard-dns" 1500 4000 "20G"
  create_dvm_template "dvm-untrusted" "red" "adguard-dns" 800 2000 "10G"

  create_named_dispvm "work-gmail" "dvm-work-gmail" "green" "adguard-dns" 800 2000
  create_named_dispvm "work-github" "dvm-work-github" "blue" "adguard-dns" 800 2500
  create_named_dispvm "work-aws" "dvm-work-aws" "orange" "aws-openvpn" 1000 3000
  create_named_dispvm "ssh-admin" "dvm-ssh-admin" "purple" "adguard-dns" 600 1200
  create_named_dispvm "dev-containers" "dvm-dev-containers" "yellow" "adguard-dns" 1500 4000
  create_named_dispvm "untrusted" "dvm-untrusted" "red" "adguard-dns" 800 2000

  create_disp_template "disp-browser-template"
  qvm-prefs default_dispvm "$DISPVM_TEMPLATE" || true

  qvm-prefs "vault" autostart false
  qvm-prefs "suricata-ips" autostart false
  qvm-prefs "adguard-dns" autostart false
  qvm-prefs "aws-openvpn" autostart false

  # Apply Qubes-level outbound policy to dev-containers named disposable.
  # This is not a substitute for container namespace controls; it limits the qube's outward network.
  qvm-firewall dev-containers reset || true
  qvm-firewall dev-containers add accept proto=tcp dstports=80,443 || true
  qvm-firewall dev-containers add accept proto=udp dstports=53 || true
  qvm-firewall dev-containers add drop || true

  write_notes_to_vm "vault" "Vault qube: keep recovery codes, offline notes, and SSH private keys here. Do not give this qube network access."
  write_notes_to_vm "dvm-work-gmail" "Disposable template for Gmail-only named disposable. Shutdown/recreate work-gmail after risky activity."
  write_notes_to_vm "dvm-work-github" "Disposable template for GitHub/Git work. Do not store long-lived production keys here."
  write_notes_to_vm "dvm-work-aws" "Disposable template for AWS Console/CLI, routed through aws-openvpn."
  write_notes_to_vm "dvm-ssh-admin" "Disposable template for SSH client work. Prefer Split SSH or hardware security keys."
  write_notes_to_vm "dvm-dev-containers" "Disposable template for rootless container/dev services. The named dev-containers qube is disposable."
  write_notes_to_vm "dvm-untrusted" "Disposable template for untrusted links and files only."
  write_notes_to_vm "adguard-dns" "Rebuildable service qube: rootless AdGuard Home DNS filtering container with cloudflared DoH companion."
  write_notes_to_vm "aws-openvpn" "Rebuildable service qube: AWS OpenVPN ProxyVM. Import your .ovpn with sudo import-aws-openvpn-config."
  write_notes_to_vm "suricata-ips" "Rebuildable service qube: Suricata IDS/IPS ProxyVM using NFQUEUE."
  write_notes_to_vm "caddy-web" "Rebuildable service qube: rootless Caddy reverse proxy with strict security headers."
  write_notes_to_vm "portainer-mgmt" "Rebuildable service qube: rootless Portainer for local Podman image/container management."
  write_notes_to_vm "untrusted" "Untrusted links and files only."

  install_rootless_container_guard
  install_suricata_ips_container
  install_adguard_container
  install_aws_openvpn_container
  install_caddy_web_container
  install_portainer_mgmt_container
  create_recreate_tool

  log "Created compartment layout."
  cat <<EOF

Next manual hardening steps:

1. Install Podman and networking tools in the template, not dom0, then rerun this script:
     qvm-run -u root $TEMPLATE 'dnf install -y podman slirp4netns fuse-overlayfs shadow-utils iptables iproute bind-utils curl tar gzip'
   AWS OpenVPN and Suricata containers build locally and need Podman available.
   Caddy runs from the official caddy:2-alpine image and also needs Podman available.
   Portainer runs from portainer/portainer-ce and needs the rootless Podman user socket.

2. In dev-containers, use:
     podman info
     podman run --rm alpine id

   dev-containers is now a named DisposableVM. Shutdown and restart it, or run:
     sudo qubes-recreate-compartment dev-containers

3. The dvm-dev-containers inherited Podman wrapper blocks:
     sudo/root podman
     --privileged
     --network=host / --net=host
     host PID/IPC/UTS/user namespaces
     --cap-add
     --device
     slirp4netns host loopback access

4. Fresh slate:
     sudo qubes-recreate-compartment all-apps
   This is also enabled automatically at dom0 boot by:
     qubes-fresh-slate-on-boot.service

5. Keep vault offline:
     qvm-prefs vault netvm ""

6. For SSH:
   - safest: hardware security key
   - good: Split SSH with private keys in vault
   - acceptable: SSH keys only in ssh-admin, never in Gmail/browser qubes

EOF
}

main "$@"
```
