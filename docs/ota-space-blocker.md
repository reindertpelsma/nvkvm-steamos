# The NVIDIA userspace does not fit a stock SteamOS slot — OPEN, release-relevant

MEASURED 2026-08-29 on a vast.ai RTX 3060 box, on a genuine dual-slot install
taking the real OTA path (`steamos-update` → our hook → provision the new slot).

## What happens

The OTA downloads and applies fine. Our hook then provisions the newly written
slot and refuses:

```
[nvkvm] short of space for the NVIDIA userspace; reclaiming 352M of device firmware a VM cannot use
[nvkvm] ERROR: not enough space for the NVIDIA userspace: free=726M needed=768M
```

42 MB short — *after* already reclaiming the firmware. The hook then fails the
update, which is the correct behaviour, but it means a user's first OTA fails.

## Why slot A survives and slot B does not

| slot | image | free before provisioning | firmware still present |
|---|---|---|---|
| A | 20260707.10 (OOBE) | enough | yes, 312M |
| B | 20260716.1 | 733M after reclaiming 352M | no |

The newer image is simply bigger. Slot A never had to reclaim anything; slot B
reclaims everything available and is still short.

## The estimate is the real problem

Forced through with headroom (204M+51M+35M+107M of wallpapers, jupiter_bios,
fwupd and ibus removed by hand), the **full** profile installed cleanly:

```
free before: 988M    free after: 630M    -> actually consumed ~358M
```

So the pre-flight demands **768M for an install that needs ~358M**, and refuses
a slot that would have succeeded. Fixing the estimate is likely the whole fix;
no reclaiming of user-visible content is needed.

## And when it does run out, it does not fail cleanly

With `NVKVM_NO_COMPAT32=1` the pre-flight passed and the installer then died
mid-write:

```
Received signal SIGBUS; aborting.
[nvkvm] ERROR: nvidia-installer failed
```

SIGBUS is what ENOSPC looks like through an mmap. **This is the mechanism that
produced the truncated install behind the KWin display failure** — the installer
dies part-way, and before the completeness check landed
(`nvidia_userspace_complete`), the version-only probe then reported "matches
host" forever and nothing ever repaired it. The completeness check catches the
aftermath; this issue is the cause.

Note the installer's own rollback did work here — the slot was left with 0
nvidia libraries rather than a half-written tree — so SIGBUS does not *always*
leave the damaged state. That it sometimes does is enough.

## Suggested order of work

1. Fix the pre-flight estimate (measure the real installed footprint, not a
   worst-case peak). Highest value, no user-visible cost.
2. Treat a SIGBUS/partial install as a hard failure of that step, so it can
   never be mistaken for success.
3. Only then consider reclaiming more, and prefer things a VM genuinely cannot
   use (`jupiter_bios` 51M, `fwupd` 35M) over anything a user would notice.
