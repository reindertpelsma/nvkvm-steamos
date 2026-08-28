.PHONY: build up down ps logs ssh check

build:
	docker compose build

up:
	docker compose up --build -d

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
