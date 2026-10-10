#!/usr/bin/env bash

VERSION="2.0.0"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/s"
CONFIG_FILE="$HOME/.ssh/quick_ssh.conf"
KEY_FILE="$HOME/.ssh/id_ed25519"

# Exit codes (sysexits.h values, so they rarely collide with a remote
# command's own exit status passed through by `s run`).
EX_USAGE=64      # bad arguments
EX_NOHOST=68     # no saved connection by that name
EX_CANTCREAT=73  # name already taken by a different target (use --force)
EX_NOPERM=77     # passwordless login is not working / could not be set up

RESERVED_NAMES=" ls list get run check add rm help version "

# Extra ssh options from the environment, e.g. S_SSH_OPTS="-p 2222".
# They come first so they win over the defaults below (ssh keeps the first
# value it sees for each option).
SSH_OPTS=()
if [[ -n "${S_SSH_OPTS:-}" ]]; then
    read -ra SSH_OPTS <<< "$S_SSH_OPTS"
fi

self_install() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    [[ "$self" == "$INSTALL_PATH" ]] && return 0
    [[ -f "$self" ]] || return 0
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

# ---------- config file helpers ----------

# conf_lookup <name> — print the target saved under exactly <name>.
conf_lookup() {
    local name="$1" line
    [[ -f "$CONFIG_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" == *=* ]] || continue
        if [[ "${line%%=*}" == "$name" ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$CONFIG_FILE"
    return 1
}

# conf_write <name> [target] — set <name> to <target>, or remove <name> when
# no target is given. Rewrites the file atomically. Returns 0 if <name>
# existed before, 1 if it did not.
conf_write() {
    local name="$1" target="${2:-}" tmp line existed=1
    tmp="$(mktemp "$CONFIG_FILE.XXXXXX")" || return 2
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            if [[ "$line" == *=* && "${line%%=*}" == "$name" ]]; then
                existed=0
                continue
            fi
            printf '%s\n' "$line"
        done < "$CONFIG_FILE" > "$tmp"
    fi
    [[ -n "$target" ]] && printf '%s=%s\n' "$name" "$target" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 2; }
    return $existed
}

# with_lock <cmd...> — run a config mutation under an exclusive lock so two
# concurrent invocations can't lose each other's writes.
with_lock() {
    if command -v flock >/dev/null 2>&1; then
        (
            flock -w 10 9 || { echo "s: could not lock $CONFIG_FILE" >&2; exit 1; }
            "$@"
        ) 9>"$CONFIG_FILE.lock"
    else
        "$@"
    fi
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$RESERVED_NAMES" != *" $1 "* ]]
}

valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9._:%-]+$ && "$1" != -* ]]
}

# Usernames may contain DOMAIN\user or user@domain (Windows), but never
# whitespace, '=' (the config separator) or a leading '-' (ssh option).
valid_user() {
    [[ -n "$1" && "$1" != -* && "$1" != *[[:space:]=]* ]]
}

# ---------- remote key installation (shared by [a] and `s add`) ----------

# Options for the ssh calls inside install_remote_key, and an optional
# command prefix for them (setsid, for askpass on old OpenSSH).
INSTALL_OPTS=()
SSH_WRAP=()

# key_usable — 0 if $KEY_FILE exists and has no passphrase.
key_usable() {
    [[ -f "$KEY_FILE" ]] && ssh-keygen -y -P "" -f "$KEY_FILE" >/dev/null 2>&1
}

# install_remote_key <user> <host> — append our public key on the remote.
# Prints progress; returns non-zero if the install clearly failed.
install_remote_key() {
    local user="$1" host="$2" pubkey
    pubkey="$(< "${KEY_FILE}.pub")"

    echo "Detecting remote OS..."
    local os_check
    os_check=$("${SSH_WRAP[@]}" ssh "${INSTALL_OPTS[@]}" "$user@$host" 'uname -s 2>/dev/null || echo WINDOWS' 2>&1 < /dev/null)

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
    local install_out install_rc

    if [[ $is_windows -eq 1 ]]; then
        # PowerShell commands for Windows OpenSSH
        # Windows admin users need key in C:\ProgramData\ssh\administrators_authorized_keys
        # Regular users use %USERPROFILE%\.ssh\authorized_keys
        # We'll install to BOTH locations to cover both cases

        # Inside a PowerShell single-quoted string, ' is escaped as ''
        local ps_key="${pubkey//\'/\'\'}"

        # Install key to user's .ssh folder
        echo "  Installing to user authorized_keys..."
        "${SSH_WRAP[@]}" ssh "${INSTALL_OPTS[@]}" "$user@$host" "\$d=\"\$env:USERPROFILE\\.ssh\"; \$f=\"\$d\\authorized_keys\"; \$k='$ps_key'; if(!(Test-Path \$d)){New-Item -ItemType Directory -Path \$d -Force|Out-Null}; if(!((Test-Path \$f) -and (Select-String -Path \$f -Pattern \$k -SimpleMatch -Quiet))){Add-Content -Path \$f -Value \$k}" 2>&1 < /dev/null

        # Also install to administrators_authorized_keys (requires admin rights, may fail for non-admins)
        echo "  Installing to administrators_authorized_keys (for admin users)..."
        "${SSH_WRAP[@]}" ssh "${INSTALL_OPTS[@]}" "$user@$host" "\$f='C:\\ProgramData\\ssh\\administrators_authorized_keys'; if(!(Test-Path \$f)){New-Item -ItemType File -Path \$f -Force|Out-Null}; \$k='$ps_key'; if(!(Select-String -Path \$f -Pattern \$k -SimpleMatch -Quiet -ErrorAction SilentlyContinue)){Add-Content -Path \$f -Value \$k}; Write-Output 'REMOTE_OK'" 2>&1 < /dev/null

        # Windows install results are unreliable; verification decides.
        install_out="REMOTE_OK"
        install_rc=0
    else
        # The key is sent on stdin so its comment can never break the quoting.
        local remote_cmd='IFS= read -r k || exit 1
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
grep -qxF "$k" ~/.ssh/authorized_keys || printf "%s\n" "$k" >> ~/.ssh/authorized_keys
chmod go-w ~
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
echo REMOTE_OK'
        install_out=$(printf '%s\n' "$pubkey" | "${SSH_WRAP[@]}" ssh "${INSTALL_OPTS[@]}" "$user@$host" "$remote_cmd" 2>&1)
        install_rc=$?
    fi
    echo "$install_out"

    if [[ $install_rc -ne 0 || "$install_out" != *"REMOTE_OK"* ]]; then
        echo
        echo "Key install step did not complete cleanly (rc=$install_rc)."
        return 1
    fi
    LAST_INSTALL_WINDOWS=$is_windows
    return 0
}

# verify_passwordless <target> — 0 if key-based login works with no prompt.
verify_passwordless() {
    ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout="${S_CONNECT_TIMEOUT:-10}" \
        -o StrictHostKeyChecking=accept-new \
        "$1" 'echo VERIFY_OK' 2>/dev/null < /dev/null | grep -q 'VERIFY_OK'
}

# ---------- interactive menu ----------

show_menu() {
    echo
    echo "======================================"
    echo "Saved connections:"
    echo
    if [[ -s "$CONFIG_FILE" ]]; then
        while IFS='=' read -r num target; do
            [[ -n "$num" ]] && echo "[$num] ${target%$'\r'}"
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

    if ! valid_host "$FULL_IP" || ! valid_user "$USERNAME"; then
        echo
        echo "Invalid IP/hostname or username — cancelled."
        read -rp "Press Enter to continue..."
        return
    fi

    LAST_NUM="${FULL_IP##*.}"
    echo
    echo "Will save as [$LAST_NUM] for $USERNAME@$FULL_IP"
    echo

    if [[ ! -f "$KEY_FILE" ]]; then
        echo "Generating SSH key..."
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
        echo
    elif ! key_usable; then
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

    echo "Saving [$LAST_NUM] first..."
    local new_target="$USERNAME@$FULL_IP"
    local existing_target
    existing_target=$(conf_lookup "$LAST_NUM")

    if [[ -n "$existing_target" ]]; then
        if [[ "$existing_target" == "$new_target" ]]; then
            echo "[$LAST_NUM] already points to $USERNAME@$FULL_IP — no change needed."
        else
            echo "[$LAST_NUM] already exists: $existing_target"
            echo
            echo "Options:"
            echo "  [u] Update [$LAST_NUM] to point to $USERNAME@$FULL_IP"
            echo "  [n] Use a new shortcut (enter custom name)"
            echo "  [c] Cancel"
            echo
            read -rp "Choice: " CONFLICT_CHOICE
            case "$CONFLICT_CHOICE" in
                u|U)
                    with_lock conf_write "$LAST_NUM" "$new_target"
                    echo "Updated [$LAST_NUM] to $USERNAME@$FULL_IP"
                    ;;
                n|N)
                    read -rp "Enter new shortcut name: " NEW_SHORTCUT
                    if [[ -z "$NEW_SHORTCUT" ]]; then
                        echo "No shortcut entered — cancelled."
                        read -rp "Press Enter to continue..."
                        return
                    fi
                    if ! valid_name "$NEW_SHORTCUT"; then
                        echo "Invalid shortcut (letters, digits, . _ - only; not a command name) — cancelled."
                        read -rp "Press Enter to continue..."
                        return
                    fi
                    if conf_lookup "$NEW_SHORTCUT" >/dev/null; then
                        echo "[$NEW_SHORTCUT] is already taken — cancelled."
                        read -rp "Press Enter to continue..."
                        return
                    fi
                    LAST_NUM="$NEW_SHORTCUT"
                    with_lock conf_write "$LAST_NUM" "$new_target"
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
        with_lock conf_write "$LAST_NUM" "$new_target"
        echo "Saved."
    fi
    echo

    INSTALL_OPTS=("${SSH_OPTS[@]}")
    LAST_INSTALL_WINDOWS=0
    if ! install_remote_key "$USERNAME" "$FULL_IP"; then
        echo "Connection is still saved — you can use [$LAST_NUM] with a password."
        read -rp "Press Enter to continue..."
        return
    fi

    echo
    echo "Verifying passwordless login..."
    if verify_passwordless "$new_target"; then
        echo "Passwordless login verified."
    else
        echo
        echo "Key installed but passwordless still fails."
        if [[ $LAST_INSTALL_WINDOWS -eq 1 ]]; then
            echo
            echo "For Windows, ensure:"
            echo "  1. OpenSSH Server is running (Get-Service sshd)"
            echo "  2. Check C:\\ProgramData\\ssh\\sshd_config for PubkeyAuthentication yes"
            echo "  3. For admin users, key may need to be in C:\\ProgramData\\ssh\\administrators_authorized_keys"
        else
            echo "Remote diagnostics:"
            echo
            ssh "${SSH_OPTS[@]}" "$new_target" '
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
        ssh "${SSH_OPTS[@]}" "$new_target"
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
        [[ -n "$num" ]] && echo "[$num] ${target%$'\r'}"
    done < "$CONFIG_FILE"
    echo
    read -rp "Enter number to delete (or Enter to cancel): " DEL_CHOICE
    [[ -z "$DEL_CHOICE" ]] && return

    local target
    if target=$(conf_lookup "$DEL_CHOICE"); then
        with_lock conf_write "$DEL_CHOICE"
        echo "Deleted [$DEL_CHOICE] $target"
        echo "Done."
    else
        echo "[$DEL_CHOICE] not found."
    fi
    read -rp "Press Enter to continue..."
}

try_connect() {
    local choice="$1" target
    if ! target=$(conf_lookup "$choice"); then
        echo "Invalid choice: $choice"
        read -rp "Press Enter to continue..."
        return
    fi
    echo "Connecting to $target..."
    ssh "${SSH_OPTS[@]}" "$target"
    exit 0
}

interactive_menu() {
    while true; do
        show_menu
        # Exit on EOF instead of redrawing the menu forever when stdin closes.
        read -rp "Enter choice: " CHOICE || { echo; exit 0; }
        case "$CHOICE" in
            a|A) add_new ;;
            d|D) delete_connection ;;
            q|Q) exit 0 ;;
            "") ;;
            *) try_connect "$CHOICE" ;;
        esac
    done
}

# ---------- non-interactive CLI ----------

usage() {
    cat <<'EOF'
Usage:
  s                              interactive menu
  s ls [--json]                  list saved connections (name<TAB>target)
  s get <name>                   print the saved user@host
  s run <name> [--] <command>    run one command remotely, never prompts
  s check <name>                 exit 0 if passwordless login works
  s add <host> <user> [opts]     save a connection and set up key login
  s add <user@host> [opts]
      --name <name>              shortcut name (default: last IPv4 octet,
                                 else the first hostname label)
      --force                    replace an existing name with a new target
      --no-key                   only save, skip key setup
      --password-stdin           read the remote password from stdin
                                 (or set S_PASSWORD)
  s rm <name>                    delete a saved connection
  s <name>                       connect interactively (needs a terminal)
  s <name> <command>             same as: s run <name> <command>
  s help | s version

Exit codes:
  0   success          64  usage error       68  unknown name
  73  name taken (use --force)               77  key login not working
  s run / s <name> <command> return the remote command's exit status
  (255 = ssh connection or authentication failure).

Environment:
  S_SSH_OPTS          extra ssh options, e.g. "-p 2222 -i ~/.ssh/other"
  S_CONNECT_TIMEOUT   connect timeout in seconds (default 10)
  S_PASSWORD          remote password for `s add` (alternative to
                      --password-stdin)

Non-interactive commands never prompt. Unknown host keys are accepted on
first contact (StrictHostKeyChecking=accept-new); changed host keys fail.
EOF
}

die() {
    local rc="$1"
    shift
    echo "s: $*" >&2
    exit "$rc"
}

# Options for every non-interactive ssh call: never prompt, fail fast,
# notice dead connections.
batch_opts() {
    BATCH_OPTS=("${SSH_OPTS[@]}"
        -o BatchMode=yes
        -o ConnectTimeout="${S_CONNECT_TIMEOUT:-10}"
        -o StrictHostKeyChecking=accept-new
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=3)
}

lookup_or_die() {
    conf_lookup "$1" || die $EX_NOHOST "no saved connection named '$1'"
}

json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

cmd_ls() {
    local json=0 line first=1
    case "${1:-}" in
        "") ;;
        --json) json=1 ;;
        *) die $EX_USAGE "ls: unknown option '$1'" ;;
    esac
    [[ $json -eq 1 ]] && printf '['
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ "$line" == *=* && -n "${line%%=*}" ]] || continue
            if [[ $json -eq 1 ]]; then
                [[ $first -eq 1 ]] || printf ','
                first=0
                printf '{"name":%s,"target":%s}' "$(json_str "${line%%=*}")" "$(json_str "${line#*=}")"
            else
                printf '%s\t%s\n' "${line%%=*}" "${line#*=}"
            fi
        done < "$CONFIG_FILE"
    fi
    [[ $json -eq 1 ]] && printf ']\n'
    return 0
}

cmd_get() {
    [[ $# -eq 1 ]] || die $EX_USAGE "usage: s get <name>"
    lookup_or_die "$1"
}

cmd_run() {
    [[ $# -ge 1 ]] || die $EX_USAGE "usage: s run <name> [--] <command>"
    local name="$1" target
    shift
    [[ "${1:-}" == "--" ]] && shift
    [[ "$*" =~ [^[:space:]] ]] || die $EX_USAGE "run: missing command (an empty command would open a shell)"
    target="$(lookup_or_die "$name")" || exit $?
    batch_opts
    exec ssh "${BATCH_OPTS[@]}" -- "$target" "$@"
}

cmd_check() {
    [[ $# -eq 1 ]] || die $EX_USAGE "usage: s check <name>"
    local target
    target="$(lookup_or_die "$1")" || exit $?
    if verify_passwordless "$target"; then
        echo "ok $1 $target"
    else
        die $EX_NOPERM "passwordless login to $target failed"
    fi
}

cmd_rm() {
    [[ $# -eq 1 ]] || die $EX_USAGE "usage: s rm <name>"
    local target rc
    target="$(lookup_or_die "$1")" || exit $?
    with_lock conf_write "$1"
    rc=$?
    [[ $rc -le 1 ]] || die 1 "could not write $CONFIG_FILE"
    echo "removed $1 $target"
}

# Save <name>=<target> unless <name> holds a different target and !force.
# Runs under with_lock so the check and the write are atomic.
conf_add_checked() {
    local name="$1" target="$2" force="$3" existing rc
    if existing="$(conf_lookup "$name")"; then
        if [[ "$existing" == "$target" ]]; then
            echo "$name already points to $target"
            return 0
        fi
        if [[ "$force" -ne 1 ]]; then
            echo "s: '$name' already points to $existing (use --force to replace, or --name to pick another)" >&2
            return $EX_CANTCREAT
        fi
    fi
    conf_write "$name" "$target"
    rc=$?
    [[ $rc -le 1 ]] || { echo "s: could not write $CONFIG_FILE" >&2; return 1; }
    if [[ -n "$existing" ]]; then
        echo "updated $name $target (was $existing)"
    else
        echo "saved $name $target"
    fi
}

ssh_version_at_least() {  # ssh_version_at_least <major> <minor>
    local v
    v="$(ssh -V 2>&1)"
    [[ "$v" =~ OpenSSH_([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > $1 || (BASH_REMATCH[1] == $1 && BASH_REMATCH[2] >= $2) ))
}

cmd_add() {
    local host="" user="" name="" force=0 no_key=0 pw_stdin=0
    local -a pos=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) [[ $# -ge 2 ]] || die $EX_USAGE "add: --name needs a value"; name="$2"; shift 2 ;;
            --name=*) name="${1#--name=}"; shift ;;
            --force) force=1; shift ;;
            --no-key) no_key=1; shift ;;
            --password-stdin) pw_stdin=1; shift ;;
            --) shift; pos+=("$@"); break ;;
            -*) die $EX_USAGE "add: unknown option '$1'" ;;
            *) pos+=("$1"); shift ;;
        esac
    done
    case ${#pos[@]} in
        1) [[ "${pos[0]}" == *@* ]] || die $EX_USAGE "usage: s add <host> <user>  or  s add <user@host>"
           user="${pos[0]%@*}"; host="${pos[0]##*@}" ;;
        2) host="${pos[0]}"; user="${pos[1]}" ;;
        *) die $EX_USAGE "usage: s add <host> <user>  or  s add <user@host>" ;;
    esac
    valid_host "$host" || die $EX_USAGE "add: invalid host '$host'"
    valid_user "$user" || die $EX_USAGE "add: invalid user '$user'"

    if [[ -z "$name" ]]; then
        if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            name="${host##*.}"
        elif [[ "$host" == *:* ]]; then
            name="${host##*:}"
        else
            name="${host%%.*}"
        fi
        valid_name "$name" || die $EX_USAGE "add: can't derive a usable name from '$host'; pass --name"
    else
        valid_name "$name" || die $EX_USAGE "add: invalid name '$name' (letters, digits, . _ - ; not a command name)"
    fi

    local password=""
    if [[ $pw_stdin -eq 1 ]]; then
        IFS= read -r password || [[ -n "$password" ]] || die $EX_USAGE "add: --password-stdin given but stdin was empty"
        password="${password%$'\r'}"
    elif [[ -n "${S_PASSWORD:-}" ]]; then
        password="$S_PASSWORD"
    fi

    local target="$user@$host" rc
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    with_lock conf_add_checked "$name" "$target" "$force"
    rc=$?
    [[ $rc -eq 0 ]] || exit $rc

    [[ $no_key -eq 1 ]] && return 0

    if [[ ! -f "$KEY_FILE" ]]; then
        echo "generating $KEY_FILE" >&2
        ssh-keygen -q -t ed25519 -f "$KEY_FILE" -N "" < /dev/null >&2 ||
            die $EX_NOPERM "ssh-keygen failed (entry saved)"
    elif ! key_usable; then
        die $EX_NOPERM "$KEY_FILE has a passphrase; strip it with 'ssh-keygen -p -f $KEY_FILE' or run 's' interactively (entry saved)"
    fi

    if verify_passwordless "$target"; then
        echo "passwordless login already works for $target"
        return 0
    fi

    # Authenticate the key install: password via askpass, or let ssh prompt
    # if a human is at a terminal, otherwise give up cleanly.
    INSTALL_OPTS=("${SSH_OPTS[@]}"
        -o ConnectTimeout="${S_CONNECT_TIMEOUT:-10}"
        -o StrictHostKeyChecking=accept-new)
    if [[ -n "$password" ]]; then
        local askpass_dir
        askpass_dir="$(mktemp -d)" || die 1 "mktemp failed"
        trap 'rm -rf "$askpass_dir"' EXIT
        printf '#!/bin/sh\nprintf "%%s\\n" "$S_ASKPASS_PW"\n' > "$askpass_dir/askpass"
        chmod 700 "$askpass_dir/askpass"
        export S_ASKPASS_PW="$password" SSH_ASKPASS="$askpass_dir/askpass"
        export SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-none}"
        INSTALL_OPTS+=(-o NumberOfPasswordPrompts=1 -o "PreferredAuthentications=password,keyboard-interactive,publickey")
        # OpenSSH < 8.4 ignores SSH_ASKPASS_REQUIRE; it uses askpass only
        # without a controlling terminal.
        if ! ssh_version_at_least 8 4 && command -v setsid >/dev/null 2>&1; then
            SSH_WRAP=(setsid -w)
        fi
    elif [[ ! -t 0 ]]; then
        die $EX_NOPERM "key not installed: no password given and no terminal; rerun with --password-stdin or S_PASSWORD (entry saved as '$name')"
    fi

    LAST_INSTALL_WINDOWS=0
    install_remote_key "$user" "$host" >&2
    rc=$?
    unset S_ASKPASS_PW
    [[ $rc -eq 0 ]] || die $EX_NOPERM "key install failed for $target (entry saved as '$name')"

    if verify_passwordless "$target"; then
        echo "passwordless login verified for $target"
    else
        if [[ $LAST_INSTALL_WINDOWS -eq 1 ]]; then
            die $EX_NOPERM "key installed but passwordless login fails; see docs/windows-authorized-keys.md (entry saved as '$name')"
        fi
        die $EX_NOPERM "key installed but passwordless login fails (entry saved as '$name')"
    fi
}

# ---------- main ----------

if [[ $# -gt 0 ]]; then
    self_install >&2
else
    self_install
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$CONFIG_FILE"

[[ $# -eq 0 ]] && interactive_menu

cmd="$1"
shift
case "$cmd" in
    ls|list) cmd_ls "$@" ;;
    get) cmd_get "$@" ;;
    run) cmd_run "$@" ;;
    check) cmd_check "$@" ;;
    add) cmd_add "$@" ;;
    rm) cmd_rm "$@" ;;
    help|-h|--help) usage ;;
    version|-V|--version) echo "s $VERSION" ;;
    -*) usage >&2; exit $EX_USAGE ;;
    *)
        target="$(conf_lookup "$cmd")" || { usage >&2; die $EX_NOHOST "unknown command or connection '$cmd'"; }
        if [[ $# -gt 0 ]]; then
            cmd_run "$cmd" "$@"
        fi
        [[ -t 0 && -t 1 ]] || die $EX_USAGE "no command given and not on a terminal; use: s run $cmd -- <command>"
        exec ssh "${SSH_OPTS[@]}" "$target"
        ;;
esac
