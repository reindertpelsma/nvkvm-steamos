# The OTA never boots: slot-B provisioning fails on an untrusted pacman keyring

**Status: OPEN, release-blocking.** `steamos-update` completes and reports
success; the machine then stays on the old slot forever. Measured end to end on
the physical PC, 2026-08-29, against nvkvm-steamos `b28af1d`.

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
