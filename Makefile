.PHONY: build up down ps logs ssh check

build:
	docker compose build

# On an X11 host the broker cannot open the display with the mounted cookie
# alone: X cookies are keyed by hostname and display and the container matches
# neither, so xauth sends nothing and the server answers "Authorization
# required, but no authorization protocol specified". Measured on GNOME/X11
# 2026-09-05 with a valid two-entry cookie, one already FamilyWild -- rewriting
# it does not help. Authorising by identity does.
#
# THE SEAT USER, NOT ROOT.  This granted root, and root is the one identity that
# cannot use it: cap_drop:ALL leaves container root without CAP_DAC_OVERRIDE,
# and mutter's Xwayland creates /tmp/.X11-unix/X0 as 0775 owned by the seat, so
# root is refused by PERMISSION before authorization is reached.  The entrypoint
# now takes the desktop uid from that same X socket, so the broker runs AS the
# seat user -- which is therefore the identity to authorise.  Classic Xorg makes
# the socket 0777, which is why granting root appeared to work on a real X11
# laptop and failed under Xwayland.
#
# Done here rather than left to the reader because every X11 user hits it, and
# the failure names the display and no cause. Announced, not silent: it grants
# an identity access to your X server. Set NVKVM_NO_XHOST=1 to skip.
# Under `sudo -E`, $SUDO_USER is the seat; a bare `sudo` has no session to act on.
up:
	@if [ -n "$${SUDO_USER:-}" ] && [ -z "$${DISPLAY:-}" ] && [ -z "$${WAYLAND_DISPLAY:-}" ]; then \
		echo "WARNING: under sudo with no DISPLAY and no WAYLAND_DISPLAY."; \
		echo "         sudo dropped your session environment, so the broker will be"; \
		echo "         pointed at a display that is not yours.  Use:  sudo -E make up"; \
	fi
	@if [ -z "$${NVKVM_NO_XHOST:-}" ] && [ -n "$${DISPLAY:-}" ] && [ -z "$${WAYLAND_DISPLAY:-}" ]; then \
		seat="$${SUDO_USER:-$$(id -un)}"; \
		echo "X11 session detected -- authorising the seat user on your X server:"; \
		echo "    xhost +si:localuser:$$seat"; \
		xhost "+si:localuser:$$seat" >/dev/null 2>&1 \
			|| echo "    (xhost failed; run it yourself, or you are not on the seat)"; \
	fi
	@set -e; \
	rt="$${XDG_RUNTIME_DIR:-/run/user/$${SUDO_UID:-$$(id -u)}}"; \
	wl="$${WAYLAND_DISPLAY:-wayland-0}"; \
	case "$$wl" in /*) sock="$$wl" ;; *) sock="$$rt/$$wl" ;; esac; \
	if [ -S "$$sock" ]; then \
		docker compose up --build -d; \
	else \
		echo "no Wayland socket at $$sock -- binding /dev/null there instead"; \
		echo "    (the broker will use X11; override with NVKVM_WAYLAND_SOCKET=...)"; \
		NVKVM_WAYLAND_SOCKET=/dev/null docker compose up --build -d; \
	fi

down:
	docker compose down

ps:
	docker compose ps

logs:
	docker compose logs -f broker vmm

ssh:
	docker compose exec vmm nvkvm-steamos-ssh

# Every test in tests/ runs, by glob rather than by name. Naming them
# individually is how seven tests written in one day ended up outside CI while
# the suite was reported as passing -- it was passing locally, where they were
# run by a different glob.
#
# A test that needs hardware, a GPU or a network must skip (exit 77), not fail.
check:
	@fail=0; for t in tests/*.sh; do \
		printf '%-38s ' "$$(basename $$t)"; \
		if bash "$$t" >/tmp/nvkvm-check.log 2>&1; then echo PASS; \
		elif [ $$? -eq 77 ]; then echo SKIP; \
		else echo FAIL; sed 's/^/    /' /tmp/nvkvm-check.log; fail=1; fi; \
	done; \
	[ $$fail -eq 0 ]
	shellcheck -S warning boot/*.sh install_steamos_vm.sh scripts/*.sh docker/*.sh tests/*.sh steamos-ssh
