# V-AGENT build
#
# `make` produces bin/vagent for the host platform. Cross-compilation targets
# use V's own `-os` flag, which shells out to a C cross-toolchain: they will
# only work if that toolchain is installed.

V ?= v
BIN := bin/vagent
SRC := cmd/vagent.v

.PHONY: all build run test fmt vet check clean install cross

all: build

build:
	@mkdir -p bin
	$(V) -o $(BIN) $(SRC)
	@echo "built $(BIN)"

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
