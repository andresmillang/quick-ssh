# quick-ssh

A tiny interactive menu for saving and reusing SSH connections, with automatic
passwordless-login setup.

Connections are keyed by the last octet of the host IP, so `192.168.0.22` becomes
`[22]` in the menu — press `22`, Enter, you're in.

## Install

### Linux / macOS

```bash
curl -O https://raw.githubusercontent.com/andresmillang/quick-ssh/main/s.sh
bash s.sh
```

The first run copies itself to `~/.local/bin/s` and (if needed) adds
`~/.local/bin` to your `PATH` in `.bashrc` / `.zshrc`. After that, just type:

```bash
s
```

from anywhere. Open a new shell (or `source ~/.bashrc`) if `s` isn't found
after the first install.

### Windows

Download `s.bat` and drop it somewhere on your `PATH` (or just in your user
folder), then run `s` from `cmd` or PowerShell. It needs the OpenSSH client,
which ships with Windows 10/11.

Unlike the shell version, `s.bat` does not self-install — copy it where you
want it.

## Usage

Type `s` for a menu:

- **[a]** — Add a new connection. Prompts for IP + username, generates an
  `ed25519` key if you don't have one, installs the public key on the remote,
  and verifies passwordless login works.
- **[d]** — Delete a saved connection.
- **[q]** — Quit.
- **any saved number** — Connect immediately.

The menu exits cleanly when stdin closes, so piping into it can't loop forever.

## Non-interactive mode (scripts & AI agents)

Give `s` arguments and it never prompts: output goes to stdout, errors to
stderr, and the exit code tells you what happened.

```bash
s ls                          # name<TAB>user@host, one per line
s ls --json                   # [{"name":"22","target":"me@192.168.0.22"}]
s get 22                      # me@192.168.0.22
s run 22 -- 'df -h /'         # run one command, exit code is the remote's
s 22 uptime                   # shorthand for: s run 22 -- uptime
s check 22                    # exit 0 if passwordless login works
s add 192.168.0.22 me         # save + set up key login
s add me@box.lan --name box   # custom shortcut name
s rm 22
```

`s add` without a terminal needs the remote password for the one-time key
install. Pass it on stdin or in the environment; it is handed to ssh through
`SSH_ASKPASS` and never appears in the process list:

```bash
printf '%s\n' "$PW" | s add 192.168.0.22 me --password-stdin
S_PASSWORD="$PW" s add 192.168.0.22 me
```

Without a password, a TTY or an already-working key, `s add` still saves the
entry and exits 77 instead of hanging on a prompt. `--no-key` only saves.
Re-adding the same target is a no-op; pointing an existing name at a
different target needs `--force`.

| Exit code | Meaning |
|---|---|
| 0 | success |
| 64 | usage error |
| 68 | no saved connection by that name |
| 73 | name already used for a different target (use `--force`) |
| 77 | passwordless login not working / key setup failed |
| *other* | `s run`: the remote command's exit status (255 = ssh connection/auth failure) |

Every non-interactive ssh call uses `BatchMode=yes`, a connect timeout
(`S_CONNECT_TIMEOUT`, default 10s), keepalives, and
`StrictHostKeyChecking=accept-new` (new hosts are trusted on first contact,
changed host keys still fail). Extra ssh options go in `S_SSH_OPTS`, e.g.
`S_SSH_OPTS="-p 2222"`; they take precedence over the defaults.

Run `s help` for the full reference.

## Files it touches

- `~/.ssh/quick_ssh.conf` — saved connections (`<last-octet>=<user>@<ip>`)
- `~/.ssh/id_ed25519` — generated if missing
- Remote `~/.ssh/authorized_keys` — appended (never overwritten)

On Windows these live under `%USERPROFILE%\.ssh\`.

## Troubleshooting

- **Windows remote still asks for a password after `[a]`** — the key probably
  went into a file `sshd` ignores, or one whose permissions it rejects. See
  [docs/windows-authorized-keys.md](docs/windows-authorized-keys.md).

## Passphrase-protected keys

If your existing `id_ed25519` has a passphrase, the script offers to either
strip it (you need the passphrase) or back up the old key and generate a new
one. `s.bat` does not handle this case — it assumes an unencrypted key.
