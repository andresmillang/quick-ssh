# quick-ssh

A tiny interactive menu for saving and reusing SSH connections, with automatic
passwordless-login setup.

Connections are keyed by the last octet of the host IP, so `192.168.0.22` becomes
`[22]` in the menu — press `22`, Enter, you're in.

## Install

```bash
curl -O https://raw.githubusercontent.com/andresmillang/quick-ssh/main/s.sh
chmod +x s.sh
./s.sh
```

## Usage

Run `./s.sh` for a menu:

- **[n]** — Add a new connection. Prompts for IP + username, generates an
  `ed25519` key if you don't have one, installs the public key on the remote,
  and verifies passwordless login works.
- **[d]** — Delete a saved connection.
- **[q]** — Quit.
- **any saved number** — Connect immediately.

## Files it touches

- `~/.ssh/quick_ssh.conf` — saved connections (`<last-octet>=<user>@<ip>`)
- `~/.ssh/id_ed25519` — generated if missing
- Remote `~/.ssh/authorized_keys` — appended (never overwritten)

## Passphrase-protected keys

If your existing `id_ed25519` has a passphrase, the script offers to either
strip it (you need the passphrase) or back up the old key and generate a new
one.
