.PHONY: test lint
test:
	bash tests/run-tests.sh

lint:
	for f in scripts/*.sh tests/run-tests.sh tests/shim/docker; do bash -n $$f || exit 1; done
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh tests/run-tests.sh tests/shim/docker || echo "shellcheck not installed, skipped"
