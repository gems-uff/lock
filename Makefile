# make test         unit tests (needs bats; run as a regular user)
# make lint         shellcheck on every script
# make docker-test  lint + unit tests inside Ubuntu (UBUNTU=26.04 by default; needs Docker)
# make e2e          end-to-end test; ONLY on a disposable VM (creates users, edits /etc)
UBUNTU ?= 26.04
SCRIPTS = src/lock install.sh etc/update-motd.d/05-lock tests/stubs/* tests/unit/*.bash tests/unit/*.bats tests/integration/*.sh

.PHONY: test lint docker-test e2e

test:
	bats tests/unit

lint:
	shellcheck -x $(SCRIPTS)

docker-test:
	docker build -q -t lock-test:$(UBUNTU) --build-arg UBUNTU=$(UBUNTU) tests >/dev/null
	docker run --rm -v "$(CURDIR)":/src:ro lock-test:$(UBUNTU) make lint test

e2e:
	sudo LOCK_E2E=1 tests/integration/run.sh
