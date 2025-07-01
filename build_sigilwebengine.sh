#!/bin/bash -e

# This script is for building python for sigil appimage
# Please run this script in docker image: ubuntu:22.04
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build ubuntu:22.04 /build/.github/workflows/build_sigilwebengine.sh
# If you need keep store build cache in docker volume, just like:
#   $ docker volume create appimage-tools
#   $ docker run --rm -v `git rev-parse --show-toplevel`:/build -v appimage-tools:/var/cache/apt -v appimage-tools:/usr/src ubuntu:22.04 /build/.github/workflows/build_sigilwebengine.sh
# Artifacts will copy to the same directory.

set -o pipefail

export PYTHON_VER="3.13.2"
export OPENSSL_VER="3.0.16"
export LC_ALL="C.UTF-8"
export DEBIAN_FRONTEND=noninteractive
export PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig
SELF_DIR="$(dirname "$(readlink -f "${0}")")"

retry() {
  # max retry 5 times
  try=5
  # sleep 30 sec every retry
  sleep_time=15
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

prepare_baseenv() {
  rm -f /etc/apt/sources.list.d/*.list*

  # keep debs in container for store cache in docker volume
  rm -f /etc/apt/apt.conf.d/*
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/01keep-debs
  echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' > /etc/apt/apt.conf.d/99-trust-https

  # Since cmake 3.23.0 CMAKE_INSTALL_LIBDIR will force set to lib/<multiarch-tuple> on Debian
  echo '/usr/local/lib/x86_64-linux-gnu' > /etc/ld.so.conf.d/x86_64-linux-gnu-local.conf
  echo '/usr/local/lib64' > /etc/ld.so.conf.d/lib64-local.conf
  retry apt-get update

  retry apt-get install -y --allow-downgrades software-properties-common apt-transport-https
  retry apt-get update

  retry apt-get install -y \
    make \
    build-essential \
    curl \
    gperf \
    bison \
    flex \
    libgbm-dev \
    libnss3-dev \
    libasound2-dev \
    libpulse-dev \
    libdrm-dev \
    libxshmfence-dev \
    libxkbfile-dev \
    libxcomposite-dev \
    libxcursor-dev \
    libxrandr-dev \
    libxi-dev \
    x11proto-dev \
    libxtst-dev \
    libxkbcommon-dev \
    libxcb-dri3-dev \
    zip \
    zlib1g-dev


  apt-get autoremove --purge -y
  # strip all compiled files by default
  export CFLAGS='-s'
  export CXXFLAGS='-s'
  # Force refresh ld.so.cache
  ldconfig
}

prepare_buildenv() {
  # Install Cmake
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry curl -ksSL --compressed https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"
    if [ -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      cd /usr/src
      cmake_sha256="$(retry curl -ksSL --compressed "${cmake_sha256_url}" \| grep "cmake-${cmake_latest_ver}-linux-x86_64.tar.gz")"
      if ! echo "${cmake_sha256}" | sha256sum -c; then
        rm -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
      fi
    fi
    if [ ! -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry curl -kLo "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" "${cmake_binary_url}"
    fi
    tar -zxf "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version

  # Install Ninja
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry curl -ksSL --compressed https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ ! -f "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok" ]; then
      rm -f "/usr/src/ninja-${ninja_ver}-linux.zip"
      retry curl -kLC- -o "/usr/src/ninja-${ninja_ver}-linux.zip" "${ninja_binary_url}"
      touch "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok"
    fi
    unzip -d /usr/local/bin "/usr/src/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

setup_python() {
  mkdir -p /opt/sigiltools
  python_url="https://github.com/dougmassay/win-qtwebkit-5.212/releases/download/v5.212-1/sigilpython${PYTHON_VER}.tar.xz"
  if [ ! -f "/usr/src/sigilpython${PYTHON_VER}.tar.xz.download_ok" ]; then
    rm -f "/usr/src/sigilpython${PYTHON_VER}.tar.xz"
    retry curl -kLC- -o "/usr/src/sigilpython${PYTHON_VER}.tar.xz" "${python_url}"
    touch "/usr/src/sigilpython${PYTHON_VER}.tar.xz.download_ok"
  fi
  tar -xJvf /opt/sigiltools "/usr/src/sigilpython${PYTHON_VER}.tar.xz"
  export PATH=/opt/sigiltools/python/bin:$PATH
  export LD_LIBRARY_PATH=/opt/sigiltools/python/lib:$LD_LIBRARY_PATH
  export PYTHONHOME=/opt/sigiltools/python
  which python3
  echo "Python version $(python3 --version)"
}

setup_nodejs() {
  curl -fsSL https://deb.nodesource.com/setup_23.x -o nodesource_setup.sh
  bash nodesource_setup.sh
  apt-get install -y nodejs
  node -v
}


time {
  prepare_baseenv
  prepare_buildenv
  setup_python
  setup_nodejs
}