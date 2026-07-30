# Passwordless login to a **Windows** host

`s` → `[a]` sets up passwordless login by appending your public key to the
remote's `~/.ssh/authorized_keys`. Against Linux and macOS that just works.
Against a **Windows** host it often doesn't, and the failure is quiet: `s`
reports the key was installed, but connecting still asks for a password.

Two different things cause this. Check them in this order — the first costs
nothing to rule out and explains most cases.

---

## 1. If the remote user is an Administrator, `~/.ssh/authorized_keys` is ignored

Windows' stock `sshd_config` ends with this block:

```
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

For **any** member of the local `Administrators` group, that overrides
`AuthorizedKeysFile`. Their home-directory `~/.ssh/authorized_keys` is never
read — so a key appended there has no effect at all, no matter how correct it is.

Check membership on the Windows host:

```powershell
Get-LocalGroupMember -Group Administrators
```

If your user is listed, the key has to go in the shared admin file instead:

```powershell
# run on the Windows host, in an elevated PowerShell
$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
Add-Content $f 'ssh-ed25519 AAAA...your key... you@yourmachine'
```

Note this file is shared by *all* administrators — it is not per-user.

Then fix its permissions, because you almost certainly just broke them → §2.

### Or: take the user out of the equation

If you'd rather keep per-user key files, either remove the account from
`Administrators`, or comment out the `Match` block in
`C:\ProgramData\ssh\sshd_config` and `Restart-Service sshd`. Both are policy
decisions — the `Match` block exists so that admin keys live somewhere a
non-admin can't write.

---

## 2. Strict-mode rejects the file's ACL

Windows OpenSSH refuses to read a key file unless:

- its **owner** is `SYSTEM` or `Administrators`, **and**
- its ACL contains **no entries other than** `SYSTEM` and `Administrators`.

That second condition is stricter than people expect. It is not "lock it down" —
it is "nothing else may appear in the list at all." Two consequences catch
almost everyone:

- **Inherited entries count.** They are not exempt for being inherited.
- **`NT SERVICE\sshd` is itself rejected**, even though `sshd` is the process
  doing the reading.

### Why this happens to nearly everyone

`C:\ProgramData\ssh` typically carries these propagating entries:

```
C:\ProgramData\ssh   NT AUTHORITY\SYSTEM:(OI)(CI)(F)
                     NT SERVICE\sshd:(OI)(CI)(F)          ← rejected
                     BUILTIN\Administrators:(I)(OI)(CI)(F)
                     CREATOR OWNER:(I)(OI)(CI)(IO)(F)     ← rejected
                     BUILTIN\Users:(I)(OI)(CI)(RX)        ← rejected
```

`(OI)(CI)` means those entries propagate to **every file created in that
directory**. So any file you create fresh in `C:\ProgramData\ssh` — via
`Set-Content`, `Out-File`, `>`, `New-Item`, notepad, or copying one in — is born
non-compliant.

This is why *appending* to an existing, already-correct file is safe, while
*creating* the file is not. `Add-Content` on a file that already exists keeps its
ACL; creating it inherits the directory's.

### The two failure modes look nothing alike

Same root cause, completely different symptoms depending on which file is wrong:

| Bad ACL on | Read when | What you see |
| --- | --- | --- |
| `ssh_host_*_key` | service **startup** | `sshd` won't start. "Service terminated unexpectedly", often with an empty log. |
| `administrators_authorized_keys` | **every auth attempt** | Service runs fine. Password auth works. Pubkey silently refused. |
| `~\.ssh\authorized_keys` | every auth attempt | Same as above, for non-admin users. |

The second row is the one that wastes time, because everything *looks* healthy
and the natural suspicion falls on the key format or `sshd_config`.

### Diagnose — don't guess

The log names the offending entry outright. On the Windows host:

```powershell
Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 40 |
  Select-Object TimeCreated,Message | Format-List
```

Look for:

```
sshd: Bad permissions. Try removing permissions for user: NT SERVICE\sshd
      (S-1-5-80-...) on file C:/ProgramData/ssh/administrators_authorized_keys.
sshd: Authentication refused.
```

Read the principal it names and remove exactly that. Don't start rewriting ACLs
on guesswork.

If the **service** won't start and the log is empty, you get no message to read —
run `sshd.exe -ddd` as `SYSTEM` (e.g. via a scheduled task) to get real output.

### Fix

```powershell
# elevated PowerShell on the Windows host
$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
icacls $f /setowner "BUILTIN\Administrators"
icacls $f /inheritance:r /grant "SYSTEM:(F)" /grant "BUILTIN\Administrators:(F)"
icacls $f      # verify: should list exactly two entries
```

Expected result:

```
BUILTIN\Administrators:(F)
NT AUTHORITY\SYSTEM:(F)
```

**`/inheritance:r` is the load-bearing flag.** Granting the two correct entries
without dropping inheritance leaves the bad inherited ones in place, and the fix
appears to do nothing. If your ACL still shows `(I)` markers, inheritance is
still on.

No service restart is needed for `authorized_keys` files — the ACL is
re-evaluated on each authentication attempt, so just try again. Host keys are
different: they're read at startup, so fixing those does require
`Restart-Service sshd`.

Same recipe for a non-admin user's file, granting that user instead:

```powershell
$f = "$env:USERPROFILE\.ssh\authorized_keys"
icacls $f /inheritance:r /grant "SYSTEM:(F)" /grant "BUILTIN\Administrators:(F)" /grant "$env:USERNAME:(F)"
```

---

## Confirm it worked

Connect again, then check the log on the Windows host:

```powershell
Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 5 |
  Select-Object TimeCreated,Message | Format-List
```

You want `Accepted publickey`:

```
sshd: Accepted publickey for youruser from 10.0.0.5 port 51731 ssh2: ED25519 SHA256:0G3ie...
```

If it says `Accepted password`, key auth is still not being used — your client
fell back. Re-check §1 (right file?) and §2 (right ACL?).

---

## What `quick-ssh` does and doesn't do here

`s` detects a Windows remote (by `uname` failing) and installs your key to
**both** locations, so §1 is handled automatically — you don't have to know
whether the remote user is an administrator.

What it does **not** do is fix ACLs, and that has a sharp edge worth knowing:

> When `C:\ProgramData\ssh\administrators_authorized_keys` doesn't already
> exist, `s` creates it with `New-Item`. Per §2, a file created in that
> directory **inherits entries that strict mode rejects** — so on a host where
> that file didn't previously exist, `s` can leave you with a key that is
> correctly installed and still ignored.

If passwordless login fails right after a first-time `[a]` against a Windows
host, this is the most likely reason. Apply the §2 fix once on the host and it
stays fixed; subsequent runs append to the existing file and preserve its ACL.

Fixing ACLs from `s` isn't really possible — it needs an elevated shell on the
remote, and the SSH session you just authenticated may not be elevated.

## Related

Setting up the Windows side from scratch (installing OpenSSH Server, the
host-key variant of this same permission bug, and a scripted fix):
[win10-enable-incoming-ssh](https://github.com/andresmillang/win10-enable-incoming-ssh).
