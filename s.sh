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
    echo "[n] Add connection"
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
    if grep -q "^$LAST_NUM=" "$CONFIG_FILE" 2>/dev/null; then
        echo "[$LAST_NUM] already exists in config — skipping save."
    else
        echo "$LAST_NUM=$USERNAME@$FULL_IP" >> "$CONFIG_FILE"
        echo "Saved."
    fi
    echo

    echo "Installing key + fixing permissions on remote... (enter password if prompted)"
    echo
    local remote_cmd
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
    local install_out
    install_out=$(ssh "$USERNAME@$FULL_IP" "$remote_cmd" 2>&1)
    local install_rc=$?
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
        echo "Key installed but passwordless still fails. Remote diagnostics:"
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
        echo
        echo "You can still use [$LAST_NUM] — it will just prompt for password."
    fi

    echo
    read -rp "Connect now? (y/n): " CONNECT_NOW
    if [[ "${CONNECT_NOW,,}" == "y" ]]; then
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
    case "${CHOICE,,}" in
        n) add_new ;;
        d) delete_connection ;;
        q) exit 0 ;;
        "") ;;
        *) try_connect "$CHOICE" ;;
    esac
done
