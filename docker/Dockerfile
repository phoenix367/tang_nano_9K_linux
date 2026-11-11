# Build environment for tang_nano_9k_linux.
#
# Contains everything the repository builds with, from Ubuntu 24.04 packages (the same OS and
# package versions as the GitHub CI, .github/workflows/ci.yml):
#   - Buildroot's host requirements: sw/build.sh clones Buildroot under $WORK and builds the
#     uClibc-ng Linux toolchain, the kernel and BusyBox itself
#   - a bare-metal RISC-V GCC (gcc-riscv64-unknown-elf, RISCV_PREFIX): the boot ROM, the
#     bare-metal tests, the CPU tests
#   - Icarus Verilog and Verilator: the unit benches, the SoC model (scripts/ci.sh)
#   - Python 3 with pyserial and Pillow, openFPGALoader: the board tools in sw/tools/
#
# The Gowin EDA tools are NOT in the image (licensed, several GB): docker/run.sh bind-mounts the
# host install at /opt/gowin and sets GOWIN_PATH; the licence server address comes with it
# (IDE/bin/gwlicense.ini). The runtime libraries gw_sh and programmer_cli need are installed.
#
# Build with docker/bootstrap.sh (it supplies the build args and writes run.sh's settings).
FROM ubuntu:24.04

ARG BUILD_UID=1000
ARG BUILD_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        # Buildroot's host requirements (manual, "System requirements") and its downloads
        build-essential gcc g++ make binutils patch perl python3 rsync bc cpio unzip file \
        findutils diffutils gawk gzip bzip2 xz-utils tar wget curl git ca-certificates \
        libncurses-dev locales \
        # bare-metal RISC-V GCC, simulators
        gcc-riscv64-unknown-elf iverilog verilator \
        # board tools
        python3-serial python3-pil python3-yaml openfpgaloader usbutils \
        # runtime libraries of the (bind-mounted) Gowin gw_sh and programmer_cli
        libtcl8.6 libglib2.0-0t64 libgl1 libglx0 libfontconfig1 libfreetype6 libdbus-1-3 \
        libasound2t64 libnss3 libnspr4 libcap2 libusb-1.0-0 \
        libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
        libxkbcommon0 libxrandr2 libxrender1 libxtst6 \
        libqt5core5a libqt5gui5 libqt5widgets5 libqt5network5 libqt5xml5 libqt5sql5 \
        libqt5concurrent5 libqt5printsupport5 libqt5qml5 libqt5quick5 libqt5quickwidgets5 \
        libqt5webchannel5 libqt5positioning5 libqt5qmlmodels5 \
        libqt5webengine5 libqt5webenginecore5 libqt5webenginewidgets5 \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user matching the host's uid/gid, so files written into the mounted repo and
# build directory belong to the host user. dialout for the UART, plugdev for the programmer.
# The image's own "ubuntu" user (uid/gid 1000) is removed first, so 1000 is free.
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g "${BUILD_GID}" builder 2>/dev/null || true; \
    useradd -m -u "${BUILD_UID}" -g "${BUILD_GID}" -G dialout,plugdev -s /bin/bash builder; \
    mkdir -p /work /build /dl /opt/gowin && chown builder:"${BUILD_GID}" /work /build /dl

# What the repo's scripts read (all overridable at run time)
ENV WORK=/build \
    GOWIN_PATH=/opt/gowin \
    RISCV_PREFIX=riscv64-unknown-elf- \
    QT_QPA_PLATFORM=offscreen \
    LANG=en_US.UTF-8

USER builder
WORKDIR /work
CMD ["/bin/bash"]
