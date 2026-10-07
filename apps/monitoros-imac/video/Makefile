CC ?= cc
PKG_CONFIG ?= pkg-config

CPPFLAGS += $(shell $(PKG_CONFIG) --cflags libdrm)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror -Wpedantic
LDLIBS += $(shell $(PKG_CONFIG) --libs libdrm)

STREAM_CPPFLAGS := $(shell $(PKG_CONFIG) --cflags gbm egl glesv2 alsa samplerate)
STREAM_LDLIBS := $(shell $(PKG_CONFIG) --libs gbm egl glesv2 alsa samplerate)

.PHONY: all clean test stream stream-test

all: stream

test: stream-test

stream: imac5k-stream

imac5k-stream: imac5k-stream.c imac5k-audio.c imac5k-audio.h imac5k-kms.c imac5k-kms.h
	$(CC) $(CPPFLAGS) $(STREAM_CPPFLAGS) $(CFLAGS) -pthread imac5k-stream.c imac5k-audio.c imac5k-kms.c -o $@ $(LDFLAGS) $(LDLIBS) $(STREAM_LDLIBS)

stream-test: imac5k-stream
	./imac5k-stream --self-test

clean:
	rm -f imac5k-stream
