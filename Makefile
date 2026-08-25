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

check:
	bash tests/steamos_boot_config_test.sh
	bash tests/container_entrypoint_test.sh
	bash tests/compose_policy_test.sh
	shellcheck -S warning boot/*.sh install_steamos_vm.sh scripts/*.sh docker/*.sh tests/*.sh steamos-ssh
