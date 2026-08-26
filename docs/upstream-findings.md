# Upstream bugs found while building nvkvm

Defects in OTHER projects, found while integrating them. Collected here so they
are not lost, and so reports can be written later without re-deriving anything.
Nothing here is an nvkvm bug; our own are in git history.

Each entry aims to be filable as-is: version, what was observed, why it happens,
and what the fix looks like.

**QEMU findings are NOT repeated here.** They already live in
`nvkvm-pv/patches/README.md`, which classifies every patch by whether it is
upstreamable and why -- e.g. `0004` (ui/console aborting on a text console) is
flagged there as a clean upstream bug intended for qemu-devel, while `0003`
(egl-helpers) and `0005` (gtk console selection) are explained as NOT
upstreamable as written. That file is the source of truth for anything under
`patches/`; restating it here would only let the two drift apart. Read it
before filing any QEMU report.

This file is for upstream defects found OUTSIDE that set.

---

## 1. PulseAudio: `pacat` swallows read errors (signedness)

**Project** PulseAudio · **File** `src/utils/pacat.c:528` and `:554`
**Affected** v17.0 through current `master` (verified 2026-08-26 — master still
reads `size_t writable, towrite, r;`)
**Introduced** `f7b8df50c71a` (2016-12-20, "pacat: Write to stream only in
frame-sized chunks"), which added the partial-frame cache and retyped `r` from
`ssize_t` to `size_t`.

```c
size_t writable, towrite, r;                                  /* :528 */
if ((r = pa_read(fd, buf + partialframe_len,
                 writable - partialframe_len, userdata)) <= 0) {   /* :554 */
```

`ssize_t pa_read(...)` returns `-1` on error. Assigned to a `size_t`, that
becomes `SIZE_MAX`; the guard `r <= 0` is then false for an unsigned type, so
the error branch is SKIPPED and the code proceeds as though it read ~2^64
bytes. `pa_frame_align()` only rounds the length down, so `towrite` reaches
`pa_stream_write()` as ~`SIZE_MAX`. That function's bounds check has the shape
`data + length <= write_data + memblock_len`, which WRAPS at that magnitude and
passes — yielding a memchunk claiming ~2^64 bytes, i.e. an unbounded
out-of-bounds read.

**Fix** one word: declare `r` as `ssize_t`.

**Reachability** needs `read()` to return `-1`. On a blocking fd `pacat` opened
itself this is hard to force: `EINTR` is retried inside `pa_read`, `EAGAIN`
needs `O_NONBLOCK` (which a writer cannot set on someone else's file
description), and all-writers-closed gives `0`, not `-1`. Latent rather than
exploitable in the configurations we tested, but it is a real memory-safety bug
in code that upstream does not treat as security-sensitive (no SECURITY.md, no
threat model, no functional change to the file since 2018).

---

## 2. QEMU: `virtio-sound` never delivers audio to the backend

*(Not in `patches/` -- we worked around it by choosing a different device, so
there is no patch carrying this analysis.)*

**Project** QEMU · **Version** 9.2.0 · **Devices** `virtio-sound-pci` with
`-audiodev wav`

The guest enumerates the card correctly (`VirtIO SoundCard`, `virtio-snd
[VirtIO PCM 0]` in `/proc/asound/cards`) and the guest's own PipeWire opens it,
but every stream ends in `Stream error: Timeout` and NOTHING is ever written to
the backend. Replacing the device with `ich9-intel-hda` + `hda-output`, with the
same `-audiodev` and the same guest, works immediately.

**Not yet narrowed, and must be before filing:** we changed device only, so it
is not established whether this is virtio-sound itself or an interaction with
the `wav` audiodev specifically. Worth retesting virtio-sound against
`-audiodev pipewire`/`pa` (which requires a QEMU built with those backends —
ours is not) before claiming a device bug.

Guest: SteamOS, kernel 6.16.12-valve24.4 (`virtio_snd` present since 5.16).

---

## Not bugs, but worth remembering

- `fs.protected_fifos=1` refuses `O_WRONLY` on a fifo you do not own inside a
  sticky world-writable directory. Correct hardening, surprising failure mode:
  EACCES regardless of the fifo's mode bits. Working as intended.
- GDM 50 has dropped X11 entirely, so `WaylandEnable=false` is a no-op. Not a
  bug; it does mean "test on legacy X" now requires starting Xorg by hand.
- `nvidia-uninstall` silently no-ops when `/var/lib/nvidia` and
  `/var/log/nvidia-installer.log` are absent — it exits 0 having removed
  nothing. Arguably should say so.
