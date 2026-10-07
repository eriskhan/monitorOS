# Build as an ordinary user; install only copies already-built artifacts.
# DESTDIR stages the exact same /usr layout without touching host services.
DESTDIR ?=
DAEMON ?= ../../target/release/monitorosd
WORKER ?= video/imac5k-stream
UNIT ?= systemd/monitorosd.service
TARGET ?= systemd/monitoros-appliance.target

.PHONY: all build install uninstall install-test service-test

all: build

build:
	cargo build --release -p monitoros-imac
	$(MAKE) -C video stream

install:
	DESTDIR="$(DESTDIR)" DAEMON="$(DAEMON)" WORKER="$(WORKER)" UNIT="$(UNIT)" TARGET="$(TARGET)" sh package.sh install

# On a running system, disable/stop the service before removing these files.
# Live operations check the manager; staging never contacts the host manager.
uninstall:
	DESTDIR="$(DESTDIR)" sh package.sh uninstall

install-test:
	sh tests/install.sh "$(abspath $(DAEMON))" "$(abspath $(WORKER))"

# Optional real user-manager regression; --require makes a missing manager fatal.
service-test:
	python3 tests/systemd.py "$(abspath $(DAEMON))" $(SERVICE_TEST_ARGS)
