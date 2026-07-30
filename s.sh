#!/usr/bin/env bash

INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/s"
CONFIG_FILE="$HOME/.ssh/quick_ssh.conf"
KEY_FILE="$HOME/.ssh/id_ed25519"

self_install() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    [[ "$self" == "$INSTALL_PATH" ]] && return 0
    [[ -f "$INSTALL_PATH" ]] && cmp -s "$self" "$INSTALL_PATH" 2>/dev/null && return 0

    if [[ -f "$INSTALL_PATH" ]]; then
        echo "Updating installed s at $INSTALL_PATH"
    else
        echo "First-time setup: installing to $INSTALL_PATH"
    fi
    mkdir -p "$INSTALL_DIR"
    cp "$self" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"

    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [[ -f "$rc" ]] || continue
        if ! grep -qF "/.local/bin" "$rc"; then
            printf '\n# Added by quick-ssh installer\n%s\n' "$path_line" >> "$rc"
            echo "Added ~/.local/bin to PATH in $rc"
        fi
    done

    echo
    echo "Installed. From now on, just type: s"
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "(open a new shell, or run: export PATH=\"\$HOME/.local/bin:\$PATH\")"
    fi
    echo
}

self_install "$@"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$CONFIG_FILE"

show_menu() {
    echo
    echo "======================================"
    echo "Saved connections:"
    echo
    if [[ -s "$CONFIG_FILE" ]]; then
        while IFS='=' read -r num target; do
            [[ -n "$num" ]] && echo "[$num] $target"
        done < "$CONFIG_FILE"
    else
        echo "(none)"
    fi
    echo
    echo "[a] Add connection"
    echo "[d] Delete connection"
    echo "[q] Quit"
    echo
}

add_new() {
    echo
    echo "=== Add New Connection ==="
    echo
    read -rp "Enter full IP (e.g., 192.168.0.22): " FULL_IP
    read -rp "Enter username: " USERNAME

    LAST_NUM="${FULL_IP##*.}"
    echo
    echo "Will save as [$LAST_NUM] for $USERNAME@$FULL_IP"
    echo

    if [[ ! -f "$KEY_FILE" ]]; then
        echo "Generating SSH key..."
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
        echo
    elif ! ssh-keygen -y -P "" -f "$KEY_FILE" >/dev/null 2>&1; then
        echo "Your SSH key has a passphrase — passwordless login will not work."
        echo
        echo "Options:"
        echo "  [1] I know the passphrase — strip it"
        echo "  [2] I don't remember it — regenerate the key (you'll need to re-add other machines)"
        echo "  [c] Cancel"
        echo
        read -rp "Choice: " KEY_CHOICE
        case "$KEY_CHOICE" in
            1)
                local old_pp
                read -rsp "Enter your current key passphrase: " old_pp
                echo
                if ssh-keygen -p -P "$old_pp" -N "" -f "$KEY_FILE" >/dev/null 2>&1; then
                    echo "Passphrase removed."
                    echo
                else
                    echo "Wrong passphrase — cannot proceed."
                    read -rp "Press Enter to continue..."
                    return
                fi
                ;;
            2)
                echo "Backing up old key to ${KEY_FILE}.bak.$(date +%s)"
                mv "$KEY_FILE" "${KEY_FILE}.bak.$(date +%s)"
                mv "${KEY_FILE}.pub" "${KEY_FILE}.pub.bak.$(date +%s)" 2>/dev/null
                ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
                echo "New key generated."
                echo
                ;;
            *)
                echo "Cancelled."
                read -rp "Press Enter to continue..."
                return
                ;;
        esac
    fi

    local pubkey
    pubkey="$(< "${KEY_FILE}.pub")"

    echo "Saving [$LAST_NUM] first..."
    local new_entry="$LAST_NUM=$USERNAME@$FULL_IP"
    local existing_entry
    existing_entry=$(grep "^$LAST_NUM=" "$CONFIG_FILE" 2>/dev/null | head -n1)

    if [[ -n "$existing_entry" ]]; then
        if [[ "$existing_entry" == "$new_entry" ]]; then
            echo "[$LAST_NUM] already points to $USERNAME@$FULL_IP — no change needed."
        else
            echo "[$LAST_NUM] already exists: ${existing_entry#*=}"
            echo
            echo "Options:"
            echo "  [u] Update [$LAST_NUM] to point to $USERNAME@$FULL_IP"
            echo "  [n] Use a new shortcut (enter custom name)"
            echo "  [c] Cancel"
            echo
            read -rp "Choice: " CONFLICT_CHOICE
            case "$CONFLICT_CHOICE" in
                u|U)
                    # Remove old entry and add new one
                    local tmp
                    tmp="$(mktemp)"
                    grep -v "^$LAST_NUM=" "$CONFIG_FILE" > "$tmp"
                    echo "$new_entry" >> "$tmp"
                    mv "$tmp" "$CONFIG_FILE"
                    echo "Updated [$LAST_NUM] to $USERNAME@$FULL_IP"
                    ;;
                n|N)
                    read -rp "Enter new shortcut name: " NEW_SHORTCUT
                    if [[ -z "$NEW_SHORTCUT" ]]; then
                        echo "No shortcut entered — cancelled."
                        read -rp "Press Enter to continue..."
                        return
                    fi
                    LAST_NUM="$NEW_SHORTCUT"
                    echo "$LAST_NUM=$USERNAME@$FULL_IP" >> "$CONFIG_FILE"
                    echo "Saved as [$LAST_NUM]"
                    ;;
                *)
                    echo "Cancelled."
                    read -rp "Press Enter to continue..."
                    return
                    ;;
            esac
        fi
    else
        echo "$new_entry" >> "$CONFIG_FILE"
        echo "Saved."
    fi
    echo

    echo "Detecting remote OS..."
    local os_check
    os_check=$(ssh "$USERNAME@$FULL_IP" 'uname -s 2>/dev/null || echo WINDOWS' 2>&1)

    local is_windows=0
    if [[ "$os_check" == *"WINDOWS"* ]] || [[ "$os_check" == *"not recognized"* ]] || [[ "$os_check" == *"CommandNotFoundException"* ]]; then
        is_windows=1
        echo "Detected Windows remote host"
    else
        echo "Detected Unix/Linux remote host ($os_check)"
    fi
    echo

    echo "Installing key on remote... (enter password if prompted)"
    echo
    local remote_cmd install_out install_rc

    if [[ $is_windows -eq 1 ]]; then
        # PowerShell commands for Windows OpenSSH
        # Use simple PowerShell that works across versions
        remote_cmd=$(cat <<'EOFPS'
$sshDir = "$env:USERPROFILE\.ssh"
$authKeys = "$sshDir\authorized_keys"
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
if (-not (Test-Path $authKeys)) { New-Item -ItemType File -Path $authKeys -Force | Out-Null }
EOFPS
)
        # First create the directory structure
        ssh "$USERNAME@$FULL_IP" "$remote_cmd" 2>&1

        # Now append the key using a simpler method - echo through SSH
        # Escape the pubkey for PowerShell
        local ps_escaped_key="${pubkey//\"/\`\"}"
        ssh "$USERNAME@$FULL_IP" "Add-Content -Path \"\$env:USERPROFILE\\.ssh\\authorized_keys\" -Value '$ps_escaped_key'; Write-Output 'REMOTE_OK'" 2>&1
        install_out=$(ssh "$USERNAME@$FULL_IP" "if (Select-String -Path \"\$env:USERPROFILE\\.ssh\\authorized_keys\" -Pattern 'ssh-ed25519' -SimpleMatch -Quiet) { Write-Output 'REMOTE_OK' } else { Write-Output 'FAILED' }" 2>&1)
        install_rc=$?
    else
        # Unix/Linux commands
        remote_cmd=$(cat <<EOF
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
grep -qxF "$pubkey" ~/.ssh/authorized_keys || echo "$pubkey" >> ~/.ssh/authorized_keys
chmod go-w ~
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
echo REMOTE_OK
EOF
)
        install_out=$(ssh "$USERNAME@$FULL_IP" "$remote_cmd" 2>&1)
        install_rc=$?
    fi
    echo "$install_out"

    if [[ $install_rc -ne 0 || "$install_out" != *"REMOTE_OK"* ]]; then
        echo
        echo "Key install step did not complete cleanly (rc=$install_rc)."
        echo "Connection is still saved — you can use [$LAST_NUM] with a password."
        read -rp "Press Enter to continue..."
        return
    fi

    echo
    echo "Verifying passwordless login..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 \
        "$USERNAME@$FULL_IP" 'echo VERIFY_OK' 2>/dev/null | grep -q '^VERIFY_OK$'; then
        echo "Passwordless login verified."
    else
        echo
        echo "Key installed but passwordless still fails."
        if [[ $is_windows -eq 1 ]]; then
            echo
            echo "For Windows, ensure:"
            echo "  1. OpenSSH Server is running (Get-Service sshd)"
            echo "  2. Check C:\\ProgramData\\ssh\\sshd_config for PubkeyAuthentication yes"
            echo "  3. For admin users, key may need to be in C:\\ProgramData\\ssh\\administrators_authorized_keys"
        else
            echo "Remote diagnostics:"
            echo
            ssh "$USERNAME@$FULL_IP" '
                echo "--- authorized_keys ---"
                cat ~/.ssh/authorized_keys 2>/dev/null || echo "(missing)"
                echo "--- permissions ---"
                ls -ld ~ ~/.ssh ~/.ssh/authorized_keys 2>/dev/null
                echo "--- sshd config ---"
                grep -riE "^\s*(AuthorizedKeysFile|PubkeyAuthentication)" \
                    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || echo "(no override)"
            '
        fi
        echo
        echo "You can still use [$LAST_NUM] — it will just prompt for password."
    fi

    echo
    read -rp "Connect now? (y/n): " CONNECT_NOW
    if [[ "$CONNECT_NOW" == "y" || "$CONNECT_NOW" == "Y" ]]; then
        ssh "$USERNAME@$FULL_IP"
    fi
}

delete_connection() {
    echo
    echo "=== Delete Connection ==="
    echo
    if [[ ! -s "$CONFIG_FILE" ]]; then
        echo "No connections to delete."
        read -rp "Press Enter to continue..."
        return
    fi

    while IFS='=' read -r num target; do
        [[ -n "$num" ]] && echo "[$num] $target"
    done < "$CONFIG_FILE"
    echo
    read -rp "Enter number to delete (or Enter to cancel): " DEL_CHOICE
    [[ -z "$DEL_CHOICE" ]] && return

    local tmp
    tmp="$(mktemp)"
    local deleted=0
    while IFS='=' read -r num target; do
        [[ -z "$num" ]] && continue
        if [[ "$num" == "$DEL_CHOICE" ]]; then
            deleted=1
            echo "Deleted [$num] $target"
        else
            echo "$num=$target" >> "$tmp"
        fi
    done < "$CONFIG_FILE"

    if [[ $deleted -eq 1 ]]; then
        mv "$tmp" "$CONFIG_FILE"
        echo "Done."
    else
        rm -f "$tmp"
        echo "[$DEL_CHOICE] not found."
    fi
    read -rp "Press Enter to continue..."
}

try_connect() {
    local choice="$1"
    local line target
    line=$(grep "^${choice}=" "$CONFIG_FILE" 2>/dev/null | head -n1)
    if [[ -z "$line" ]]; then
        echo "Invalid choice: $choice"
        read -rp "Press Enter to continue..."
        return
    fi
    target="${line#*=}"
    echo "Connecting to $target..."
    ssh "$target"
    exit 0
}

while true; do
    show_menu
    read -rp "Enter choice: " CHOICE
    case "$CHOICE" in
        a|A) add_new ;;
        d|D) delete_connection ;;
        q|Q) exit 0 ;;
        "") ;;
        *) try_connect "$CHOICE" ;;
    esac
done
