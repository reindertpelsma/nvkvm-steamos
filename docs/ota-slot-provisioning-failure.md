# The OTA never boots: slot-B provisioning fails on an untrusted pacman keyring

**Status: RESOLVED, verified 2026-09-02.** Kept for the diagnosis, which is a
good example of the failure shape ("the check read the wrong root").

The fix is `48cb655` / `f56fd8e` / `67d53db` on main: `ensure_pacman_keyring()`
now evaluates the key with `in_target`, so the gpg homedir resolves inside the
slot being provisioned rather than the running one, with a last-resort seed
from the running system and a trustdb refresh. The status line here was simply
never updated after those landed, which is why this doc still read
release-blocking on the eve of a release.

Re-measured end to end on a rented RTX 3070 host, driver 580.95.05, guest built
from `fix/steamos-profile-keeps-libcuda`:

```
[nvkvm] pacman keyring populated; package signatures now validate
[nvkvm-ota] handing the newly written slot to steamos_boot.sh --image
[nvkvm] === Part 1 finished (rc=0) ===
[nvkvm-ota] the new slot is provisioned and armed; it is safe to reboot into it
```

and the arming, which is the thing that used to be wrong:

| | before (2026-08-29) | after (2026-09-02) |
|---|---|---|
| activated slot | A -- B disarmed, `boot-requested-at: 0` | **B** |
| booted after reboot | A, forever | **B** |
| `VARIANT_ID` | `steamdeck-oobe` | **`steamdeck`** |
| `BUILD_ID` | `20260707.10` | **`20260716.1`** |

The new slot also carries the NVIDIA userspace written by its own provisioning
pass -- `libcuda` in slot B is stamped 17:52 against slot A's 17:37 -- so this
also demonstrates that provisioning reaches the OTA slot, not only the initial
install. Evidence: `nvkvm-w330-evidence/libcuda-trim-20260902/ota.log`.

The severity note below still stands as a design point: this failure mode is
silent, and the OTA stage of any sweep should assert that the activated slot
actually changed rather than trusting `steamos-update`'s exit code.

## The original report follows

## The visible symptom

```
A.conf   boot-requested-at: 20260829184125     <- armed
B.conf   boot-requested-at: 0                  <- disarmed
selected-image: A
```

`disarm_other()` is doing its job here, not misbehaving: it is the failure
handler ("refuse to boot a slot we could not provision"). The update was written
to B, provisioning B failed, and the hook correctly refused to arm it.

## The chain, from the provisioning log

```
 7  pacman keyring holds no locally-signed keys; initialising and populating
 8  pacman keyring populated; package signatures now validate     <- FALSE
47  ERROR: could not install core build tools
48  pacman keyring: signatures are trusted                        <- FALSE
69  ERROR: pacman -U failed for the exact-match headers
98  ERROR: nvidia-installer failed
136 ERROR: provisioning the new slot FAILED (rc=1)
```

Every install failed the same way:

```
error: gcc: signature from "GitLab CI Package Builder
       <ci-package-builder-1@steamos.cloud>" is unknown trust
```

## The root cause: the check reads the wrong root

Measured directly, with slot B mounted read-only from the running slot A:

| keyring | uid validity of the package-builder key |
|---|---|
| slot A (`/etc/pacman.d/gnupg`) | `uid:f:` — full, trusted |
| slot B (`/mnt/slotb/etc/pacman.d/gnupg`) | `uid:q:` — undefined, NOT trusted |

`ensure_pacman_keyring()` greps for `^uid:[fu]:.*steamos\.cloud`. `q` does not
match that, so on slot B the check should have FAILED — and it reported success,
twice. The only way both are true is that the verification inspected the running
root rather than the slot being provisioned.

That makes this the same failure shape the function's own comment warns about
("TEST THE REPO'S SIGNING KEY, NOT ANY TRUSTED KEY") one level up: the *key*
predicate was tightened, but *which keyring it is evaluated against* was not.

## What to fix

1. Make `ensure_pacman_keyring()` verify the TARGET's keyring explicitly —
   `gpg --homedir "$ROOT/etc/pacman.d/gnupg"` — rather than relying on the
   ambient one, and fail loudly when the target's builder key is not `[fu]`.
2. Then find why `pacman-key --populate` in the target leaves the key at `q`;
   populate normally locally-signs, so either it is not running in the target,
   or it is running without the target's `--gpgdir`.
3. Re-test the whole path. `ota` and `slotb` have never passed, and this is why.

## Note on severity

This is silent. `steamos-update` exits 0, the desktop offers no error, and the
only trace is a line in `/var/log/nvkvm-ota.log`. Any user who updates simply
stays on the old image and never learns. It should fail loudly, and the OTA
stage of the sweep must assert `selected-image` actually changed.
