# Makefile for the HD Mode 7 daemon (m7_daemon)
#
# Build on the MiSTer (if it has make + g++):
#   make
#
# Cross-compile from a Linux toolchain host:
#   make CROSS_COMPILE=arm-linux-gnueabihf-
#
# Static link (recommended for cross builds — the MiSTer's userspace libc
# can be older than the toolchain's):
#   make CROSS_COMPILE=arm-linux-gnueabihf- STATIC=1
#
# Install to the launcher's support directory (run on the MiSTer):
#   make install

CROSS_COMPILE ?=
CXX      = $(CROSS_COMPILE)g++
CXXFLAGS = -Wall -O2 -std=c++11
ifeq ($(STATIC),1)
LDFLAGS  += -static
endif

TARGET   = m7_daemon
OBJS     = m7_daemon.o

# Matches the support dir the launcher script (scripts/snes_hd_m7.sh) uses.
INSTALL_DIR ?= /media/fat/Scripts/.SNES_HD_M7/support

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $(TARGET) $(OBJS)

m7_daemon.o: m7_daemon.cpp m7_abi.h m7_uart_parser.h m7_mode7_renderer.h
	$(CXX) $(CXXFLAGS) -c m7_daemon.cpp

install: $(TARGET)
	install -d $(INSTALL_DIR)
	install -m 755 $(TARGET) $(INSTALL_DIR)/$(TARGET)
	( cd $(INSTALL_DIR) && sha256sum $(TARGET) > $(TARGET).sha256 )

clean:
	rm -f $(TARGET) $(OBJS) test_mode7_renderer

# Host-side parser test against a raw UART capture (no cross toolchain):
#   make test CAP=/tmp/m7tb/uart_cap.bin
CAP ?= /tmp/m7tb/uart_cap.bin

test: test_uart_parser
	./test_uart_parser $(CAP)

test_uart_parser: test_uart_parser.cpp m7_uart_parser.h
	g++ -Wall -O2 -std=c++11 -o $@ $<

test_mode7_renderer: test_mode7_renderer.cpp m7_mode7_renderer.h m7_abi.h
	g++ -Wall -O2 -std=c++11 -o $@ $<

test-renderer: test_mode7_renderer
	./test_mode7_renderer

.PHONY: all install clean test test-renderer
