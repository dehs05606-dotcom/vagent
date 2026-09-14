# V-AGENT build
#
# `make` produces bin/vagent for the host platform. Cross-compilation targets
# use V's own `-os` flag, which shells out to a C cross-toolchain: they will
# only work if that toolchain is installed.

V ?= v
BIN := bin/vagent
SRC := cmd/vagent.v

.PHONY: all build bundled run test fmt vet check clean install cross

all: build

build:
	@mkdir -p bin
	$(V) -o $(BIN) $(SRC)
	@echo "built $(BIN)"

# bundled compiles the endpoint and key into the binary, so it runs with nothing
# exported. The values come from this shell's environment and never touch the
# source tree or the Makefile.
#
#   VAGENT_API_KEY=sk-... VAGENT_BASE_URL=https://.../v1 VAGENT_MODEL=m make bundled
#
# The result contains your key in plain text -- `strings` recovers it. Treat the
# binary as the credential: do not commit it, do not share it.
bundled:
	@test -n "$$VAGENT_API_KEY" || { echo "VAGENT_API_KEY is not set"; exit 1; }
	@test -n "$$VAGENT_BASE_URL" || { echo "VAGENT_BASE_URL is not set"; exit 1; }
	@test -n "$$VAGENT_MODEL" || { echo "VAGENT_MODEL is not set"; exit 1; }
	@mkdir -p bin
	$(V) -prod \
		-d vagent_api_key="$$VAGENT_API_KEY" \
		-d vagent_base_url="$$VAGENT_BASE_URL" \
		-d vagent_model="$$VAGENT_MODEL" \
		-d vagent_provider_kind="$${VAGENT_PROVIDER_KIND:-openai}" \
		-o $(BIN) $(SRC)
	@echo "built $(BIN) with credentials compiled in -- do not share this file"

# -prod turns on optimisation; it is noticeably slower to compile.
release:
	@mkdir -p bin
	$(V) -prod -o $(BIN) $(SRC)

run: build
	./$(BIN)

test:
	$(V) test tests/

fmt:
	$(V) fmt -w cmd/ src/ tests/

vet:
	$(V) vet src/

# check is what CI runs: formatting must be canonical, and tests must pass.
check:
	$(V) fmt -verify cmd/ src/ tests/
	$(V) test tests/
	$(V) -o /dev/null $(SRC)

cross:
	@mkdir -p bin
	$(V) -os linux   -o bin/vagent-linux   $(SRC)
	$(V) -os macos   -o bin/vagent-macos   $(SRC)
	$(V) -os windows -o bin/vagent.exe     $(SRC)

install: build
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/vagent

clean:
	rm -rf bin
