#!/usr/bin/env bash
# setup-gnome-pin.sh
# Sets up a PIN for the GNOME lock screen WITHOUT affecting fresh GDM logins.
#
# How it distinguishes lock screen from login:
#   On first successful login, PAM runs a session helper that creates a flag
#   file at /run/user/<uid>/gnome-pin-session-active. This lives on a tmpfs
#   and vanishes on reboot or logout.
#
#   The auth helper only accepts the PIN if that flag file exists, meaning:
#     - Fresh boot / GDM login  → flag absent → PIN rejected → must use full password
#     - Screen locked / unlock  → flag present → PIN accepted ✓
#
# Two helpers are installed:
#   AUTH helper    (/usr/local/lib/gnome-pin-auth)
#     Called by PAM on every auth attempt. Reads the token from stdin
#     (how pam_exec expose_authtok actually works), checks flag + verifies PIN hash.
#   SESSION helper (/usr/local/lib/gnome-pin-session)
#     Called by PAM after session open. Creates the flag file for this user.
#     Injected after "session include password-auth" so that pam_systemd has
#     already created /run/user/<uid> by the time we write the flag.
#
# PAM file patched: /etc/pam.d/gdm-password
#
# Usage:
#   sudo ./setup-gnome-pin.sh            # first-time setup
#   sudo ./setup-gnome-pin.sh --update   # change the PIN
#   sudo ./setup-gnome-pin.sh --remove   # remove everything and restore PAM

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
PIN_HASH_FILE="/etc/gnome-pin-hash"
AUTH_HELPER="/usr/local/lib/gnome-pin-auth"
SESSION_HELPER="/usr/local/lib/gnome-pin-session"
PAM_FILE="/etc/pam.d/gdm-password"
PAM_BACKUP="${PAM_FILE}.bak"
PAM_AUTH_MARKER="# GNOME-PIN-SETUP-AUTH"
PAM_SESSION_MARKER="# GNOME-PIN-SETUP-SESSION"

# ── Colours ───────────────────────────────────────────────────────────────────
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ── Guards ────────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        red "This script must be run as root (use sudo)."
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    if ! command -v openssl &>/dev/null; then
        missing+=("openssl  (install with: dnf install openssl)")
    fi

    if ! find /lib /usr/lib /lib64 /usr/lib64 \
            -name "pam_exec.so" 2>/dev/null | grep -q .; then
        missing+=("pam_exec.so  (part of the pam package: dnf install pam)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        red "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

check_pam_file() {
    if [[ ! -f "$PAM_FILE" ]]; then
        red "PAM file not found: $PAM_FILE"
        echo
        echo "Available GDM-related PAM files on this system:"
        ls /etc/pam.d/ | grep -i gdm || echo "  (none found)"
        echo
        echo "Make sure GDM is installed: dnf install gdm"
        exit 1
    fi
}

# ── Read PIN securely ─────────────────────────────────────────────────────────
read_pin() {
    local pin confirm
    while true; do
        echo
        read -rsp "Enter your new PIN (digits only, min 4): " pin
        echo

        if ! [[ "$pin" =~ ^[0-9]{4,}$ ]]; then
            red "PIN must be at least 4 digits and contain only numbers. Try again."
            continue
        fi

        read -rsp "Confirm PIN: " confirm
        echo

        if [[ "$pin" != "$confirm" ]]; then
            red "PINs do not match. Try again."
            continue
        fi

        PIN="$pin"
        break
    done
}

# ── Write hashed PIN file ─────────────────────────────────────────────────────
write_pin_file() {
    local username="${SUDO_USER:-$(whoami)}"
    local hashed

    hashed=$(openssl passwd -6 "$PIN")   # SHA-512 crypt, same format as /etc/shadow

    printf '%s:%s\n' "$username" "$hashed" > "$PIN_HASH_FILE"
    chmod 600 "$PIN_HASH_FILE"
    chown root:root "$PIN_HASH_FILE"

    green "PIN stored securely in $PIN_HASH_FILE (SHA-512, root-only)."
}

# ── Write auth helper ─────────────────────────────────────────────────────────
# Called by pam_exec on every auth attempt against gdm-password.
# pam_exec with expose_authtok passes the token via stdin, not $PAM_AUTHTOK.
# Exits 0 (PIN accepted) only if:
#   1. The session flag file exists (user has already logged in this boot)
#   2. The token from stdin matches the stored PIN hash
write_auth_helper() {
    cat > "$AUTH_HELPER" << 'HELPER'
#!/usr/bin/env bash
# gnome-pin-auth: pam_exec auth helper.
# pam_exec expose_authtok pipes the token via stdin.

PIN_HASH_FILE="/etc/gnome-pin-hash"

[[ -z "${PAM_USER:-}" ]] && exit 1
[[ ! -f "$PIN_HASH_FILE" ]] && exit 1

# Only accept PIN if the session flag exists (i.e. not a fresh GDM login)
uid=$(id -u "$PAM_USER" 2>/dev/null) || exit 1
flag_file="/run/user/${uid}/gnome-pin-session-active"
[[ ! -f "$flag_file" ]] && exit 1

# Read token from stdin (how pam_exec expose_authtok actually delivers it)
read -r token

# Look up stored hash for this user
stored_hash=$(awk -F: -v user="$PAM_USER" '$1 == user { print $2; exit }' "$PIN_HASH_FILE")
[[ -z "$stored_hash" ]] && exit 1

# Re-hash with the stored salt and compare
stored_salt=$(printf '%s' "$stored_hash" | cut -d'$' -f3)
computed=$(openssl passwd -6 -salt "$stored_salt" "$token" 2>/dev/null)

if [[ "$computed" == "$stored_hash" ]]; then
    exit 0   # PIN correct → PAM grants access
else
    exit 1   # PIN wrong → PAM falls through to normal password
fi
HELPER

    chmod 700 "$AUTH_HELPER"
    chown root:root "$AUTH_HELPER"
    green "Auth helper written to $AUTH_HELPER"
}

# ── Write session helper ──────────────────────────────────────────────────────
# Injected after "session include password-auth" so pam_systemd has already
# created /run/user/<uid> by the time we write the flag file.
write_session_helper() {
    cat > "$SESSION_HELPER" << 'HELPER'
#!/usr/bin/env bash
# gnome-pin-session: pam_exec session helper.
# Creates the flag file that tells the auth helper a session is active.

[[ -z "${PAM_USER:-}" ]] && exit 0
[[ "${PAM_TYPE:-}" != "open_session" ]] && exit 0

uid=$(id -u "$PAM_USER" 2>/dev/null) || exit 0
run_dir="/run/user/${uid}"

# /run/user/<uid> is created by pam_systemd which runs inside
# "session include password-auth", before this hook. Should always exist.
[[ ! -d "$run_dir" ]] && exit 0

flag_file="${run_dir}/gnome-pin-session-active"
touch "$flag_file"
chmod 600 "$flag_file"
chown "$PAM_USER" "$flag_file"

exit 0
HELPER

    chmod 700 "$SESSION_HELPER"
    chown root:root "$SESSION_HELPER"
    green "Session helper written to $SESSION_HELPER"
}

# ── Patch PAM file ────────────────────────────────────────────────────────────
patch_pam() {
    if [[ ! -f "$PAM_BACKUP" ]]; then
        cp "$PAM_FILE" "$PAM_BACKUP"
        green "Backed up original PAM file to $PAM_BACKUP"
    fi

    # Idempotency: strip existing markers
    if grep -q "$PAM_AUTH_MARKER\|$PAM_SESSION_MARKER" "$PAM_FILE"; then
        sed -i "/$PAM_AUTH_MARKER/,+1d" "$PAM_FILE"
        sed -i "/$PAM_SESSION_MARKER/,+1d" "$PAM_FILE"
    fi

    local tmpfile
    tmpfile=$(mktemp)
    local auth_injected=0 session_injected=0

    while IFS= read -r line; do
        # Inject auth line before the first auth line
        if [[ $auth_injected -eq 0 && "$line" =~ ^auth ]]; then
            printf '%s\n' "$PAM_AUTH_MARKER"
            printf 'auth       sufficient   pam_exec.so expose_authtok %s\n' "$AUTH_HELPER"
            auth_injected=1
        fi

        printf '%s\n' "$line"

        # Inject session line AFTER "session include password-auth" so that
        # pam_systemd (inside that substack) has already run and created
        # /run/user/<uid> before our helper tries to write the flag file.
        if [[ $session_injected -eq 0 && "$line" =~ ^session.*include.*password-auth ]]; then
            printf '%s\n' "$PAM_SESSION_MARKER"
            printf 'session    optional     pam_exec.so %s\n' "$SESSION_HELPER"
            session_injected=1
        fi
    done < "$PAM_FILE" > "$tmpfile"

    # Edge cases: no auth or session include lines found
    if [[ $auth_injected -eq 0 ]]; then
        printf '%s\n' "$PAM_AUTH_MARKER" >> "$tmpfile"
        printf 'auth       sufficient   pam_exec.so expose_authtok %s\n' "$AUTH_HELPER" >> "$tmpfile"
    fi
    if [[ $session_injected -eq 0 ]]; then
        yellow "Warning: could not find 'session include password-auth' in $PAM_FILE."
        yellow "Session hook appended at end — flag file creation may race with pam_systemd."
        printf '%s\n' "$PAM_SESSION_MARKER" >> "$tmpfile"
        printf 'session    optional     pam_exec.so %s\n' "$SESSION_HELPER" >> "$tmpfile"
    fi

    mv "$tmpfile" "$PAM_FILE"
    green "Patched $PAM_FILE (auth + session hooks)."
}

# ── Actions ───────────────────────────────────────────────────────────────────
do_install() {
    if [[ -f "$PIN_HASH_FILE" ]]; then
        yellow "A PIN is already configured."
        yellow "Use --update to change it, or --remove to remove it."
        exit 1
    fi

    echo "This sets up a PIN for unlocking the GNOME lock screen."
    yellow "The PIN will NOT work at the GDM login screen (fresh boot)."
    yellow "Your full password is always required there."
    echo

    read_pin
    write_pin_file
    write_auth_helper
    write_session_helper
    patch_pam

    echo
    green "✓ Setup complete!"
    echo
    echo "  How it works:"
    echo "    1. Log in normally with your full password after a reboot."
    echo "    2. Once logged in, locking the screen (Super+L) will accept your PIN."
    echo "    3. The PIN stops working again after a reboot until you log in with your password."
    echo
    echo "  To change the PIN:  sudo $0 --update"
    echo "  To remove the PIN:  sudo $0 --remove"
}

do_update() {
    if [[ ! -f "$PIN_HASH_FILE" ]]; then
        red "No PIN is currently configured. Run without arguments to set one up first."
        exit 1
    fi

    bold "Updating GNOME lock screen PIN..."
    read_pin
    write_pin_file
    # Auth helper and PAM config don't need to change — only the hash file does.
    echo
    green "✓ PIN updated. Takes effect immediately on next lock screen."
}

do_remove() {
    bold "Removing GNOME lock screen PIN..."

    if [[ -f "$PAM_BACKUP" ]]; then
        cp "$PAM_BACKUP" "$PAM_FILE"
        green "Restored original PAM file from backup."
    elif grep -q "$PAM_AUTH_MARKER\|$PAM_SESSION_MARKER" "$PAM_FILE" 2>/dev/null; then
        sed -i "/$PAM_AUTH_MARKER/,+1d" "$PAM_FILE"
        sed -i "/$PAM_SESSION_MARKER/,+1d" "$PAM_FILE"
        green "Removed PIN lines from $PAM_FILE."
    else
        yellow "No PIN config found in $PAM_FILE — skipping PAM restore."
    fi

    [[ -f "$PIN_HASH_FILE"  ]] && { rm -f "$PIN_HASH_FILE";  green "Removed $PIN_HASH_FILE"; }
    [[ -f "$AUTH_HELPER"    ]] && { rm -f "$AUTH_HELPER";    green "Removed $AUTH_HELPER"; }
    [[ -f "$SESSION_HELPER" ]] && { rm -f "$SESSION_HELPER"; green "Removed $SESSION_HELPER"; }

    green "Done. Lock screen PIN has been removed."
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
    bold "═══════════════════════════════════════════"
    bold " GNOME Lock Screen PIN Manager"
    bold "═══════════════════════════════════════════"
    echo

    require_root

    case "${1:-}" in
        --remove)
            do_remove
            ;;
        --update)
            check_dependencies
            do_update
            ;;
        ""|--install)
            check_dependencies
            check_pam_file
            do_install
            ;;
        *)
            echo "Usage: sudo $0 [--update | --remove]"
            echo
            echo "  (no args)   Set up a PIN for the GNOME lock screen"
            echo "  --update    Change an existing PIN"
            echo "  --remove    Remove the PIN and restore the original PAM config"
            exit 1
            ;;
    esac
}

main "$@"
