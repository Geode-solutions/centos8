#!/bin/bash
# Top-level build script called from Dockerfile

# Stop at any error, show all commands
set -ex

# Set build environment variables
MY_DIR=$(dirname "${BASH_SOURCE[0]}")
. $MY_DIR/build_env.sh

# Dependencies for compiling Python that we want to remove from
# the final image after compiling Python
PYTHON_COMPILE_DEPS="zlib-devel openssl-devel libtool bzip2-devel expat-devel ncurses-devel readline-devel tk-devel gdbm-devel libdb-devel xz-devel keyutils-libs-devel krb5-devel libcom_err-devel curl-devel perl-devel"

# Libraries that are allowed as part of the manylinux2014 profile
# Extract from PEP: https://www.python.org/dev/peps/pep-0599/#the-manylinux2014-policy
# On RPM-based systems, they are provided by these packages:
# Package:    Libraries
# glib2:      libglib-2.0.so.0, libgthread-2.0.so.0, libgobject-2.0.so.0
# glibc:      libresolv.so.2, libutil.so.1, libnsl.so.1, librt.so.1, libpthread.so.0, libdl.so.2, libm.so.6, libc.so.6
# libICE:     libICE.so.6
# libX11:     libX11.so.6
# libXext:    libXext.so.6
# libXrender: libXrender.so.1
# libgcc:     libgcc_s.so.1
# libstdc++:  libstdc++.so.6
# mesa:       libGL.so.1
#
# PEP is missing the package for libSM.so.6 for RPM based system
# Install development packages (except for libgcc which is provided by gcc install)
MANYLINUX_DEPS="glibc-devel libstdc++-devel glib2-devel libX11-devel libXext-devel libXrender-devel mesa-libGL-devel libICE-devel libSM-devel"

# Get build utilities
source $MY_DIR/build_utils.sh

# See https://unix.stackexchange.com/questions/41784/can-yum-express-a-preference-for-x86-64-over-i386-packages
echo "multilib_policy=best" >> /etc/yum.conf
# Error out if requested packages do not exist
echo "skip_missing_names_on_install=False" >> /etc/yum.conf
# Make sure that locale will not be removed
sed -i '/^override_install_langs=/d' /etc/yum.conf

# https://hub.docker.com/_/centos/
# "Additionally, images with minor version tags that correspond to install
# media are also offered. These images DO NOT recieve updates as they are
# intended to match installation iso contents. If you choose to use these
# images it is highly recommended that you include RUN yum -y update && yum
# clean all in your Dockerfile, or otherwise address any potential security
# concerns."
# Decided not to clean at this point: https://github.com/pypa/manylinux/pull/129
yum -y update
yum -y install yum-utils curl
yum config-manager --enable extras

if ! which localedef &> /dev/null; then
    # somebody messed up glibc-common package to squeeze image size, reinstall the package
    yum -y reinstall glibc-common
    yum -y install glibc-locale-source glibc-langpack-en
fi

# upgrading glibc-common can end with removal on en_US.UTF-8 locale
localedef -i en_US -f UTF-8 en_US.UTF-8
curl -sL https://rpm.nodesource.com/setup_12.x | bash -

# Development tools and libraries
yum -y install \
    git \
    gcc \
    gcc-c++ \
    wget \
    nodejs \
    autoconf \
    automake \
    bison \
    bzip2 \
    diffutils \
    gettext \
    file \
    kernel-devel \
    libffi-devel \
    make \
    patch \
    unzip \
    which \
    ${YASM} \
    ${PYTHON_COMPILE_DEPS}

curl -O -L https://github.com/openssl/openssl/archive/OpenSSL_1_1_1c.tar.gz
tar -zxvf OpenSSL_1_1_1c.tar.gz
cd openssl-OpenSSL_1_1_1c
./config --prefix=/usr/local/openssl --openssldir=/usr/local/openssl no-shared no-zlib
make
make install
ls /usr/local/openssl
#echo "export PATH=/usr/local/openssl/bin:$PATH" > /etc/profile.d/openssl.sh
ls /usr/local/openssl/bin
#source /etc/profile.d/openssl.sh
ls /usr/local/openssl/lib
#openssl version
#echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl-1.1.1c.conf
#ldconfig -v
cd ..

# Compile the latest Python releases.
# (In order to have a proper SSL module, Python is compiled
# against a recent openssl [see env vars above], which is linked
# statically.
mkdir -p /opt/python
build_cpythons $CPYTHON_VERSIONS

# Create venv for auditwheel & certifi
TOOLS_PATH=/opt/_internal/tools
/opt/python/cp37-cp37m/bin/python -m venv $TOOLS_PATH
source $TOOLS_PATH/bin/activate

# Install default packages
pip install -U -r $MY_DIR/requirements.txt
# Install certifi and auditwheel
pip install -U -r $MY_DIR/requirements-tools.txt

# Make auditwheel available in PATH
ln -s $TOOLS_PATH/bin/auditwheel /usr/local/bin/auditwheel

# Our openssl doesn't know how to find the system CA trust store
#   (https://github.com/pypa/manylinux/issues/53)
# And it's not clear how up-to-date that is anyway
# So let's just use the same one pip and everyone uses
ln -s $(python -c 'import certifi; print(certifi.where())') /opt/_internal/certs.pem
# If you modify this line you also have to modify the versions in the Dockerfiles:
export SSL_CERT_FILE=/opt/_internal/certs.pem

# Deactivate the tools virtual environment
deactivate

# Install patchelf (latest with unreleased bug fixes) and apply our patches
build_patchelf $PATCHELF_VERSION $PATCHELF_HASH

yum -y install ${MANYLINUX_DEPS}
yum -y clean all > /dev/null 2>&1
yum list installed

# we don't need libpython*.a, and they're many megabytes
find /opt/_internal -name '*.a' -print0 | xargs -0 rm -f

# Strip what we can -- and ignore errors, because this just attempts to strip
# *everything*, including non-ELF files:
find /opt/_internal -type f -print0 \
    | xargs -0 -n1 strip --strip-unneeded 2>/dev/null || true
find /usr/local -type f -print0 \
    | xargs -0 -n1 strip --strip-unneeded 2>/dev/null || true

for PYTHON in /opt/python/*/bin/python; do
    # Smoke test to make sure that our Pythons work, and do indeed detect as
    # being manylinux compatible:
    $PYTHON $MY_DIR/manylinux-check.py
    # Make sure that SSL cert checking works
    $PYTHON $MY_DIR/ssl-check.py
done

# We do not need the Python test suites, or indeed the precompiled .pyc and
# .pyo files. Partially cribbed from:
#    https://github.com/docker-library/python/blob/master/3.4/slim/Dockerfile
find /opt/_internal -depth \
     \( -type d -a -name test -o -name tests \) \
  -o \( -type f -a -name '*.pyc' -o -name '*.pyo' \) | xargs rm -rf

# Fix libc headers to remain compatible with C99 compilers.
find /usr/include/ -type f -exec sed -i 's/\bextern _*inline_*\b/extern __inline __attribute__ ((__gnu_inline__))/g' {} +

if [ "${DEVTOOLSET_ROOTPATH:-}" != "" ]; then
    # remove useless things that have been installed by devtoolset
    rm -rf $DEVTOOLSET_ROOTPATH/usr/share/man
    find $DEVTOOLSET_ROOTPATH/usr/share/locale -mindepth 1 -maxdepth 1 -not \( -name 'en*' -or -name 'locale.alias' \) | xargs rm -rf
fi
rm -rf /usr/share/backgrounds
# if we updated glibc, we need to strip locales again...
localedef --list-archive | grep -v -i ^en_US.utf8 | xargs localedef --delete-from-archive
mv -f /usr/lib/locale/locale-archive /usr/lib/locale/locale-archive.tmpl
build-locale-archive
find /usr/share/locale -mindepth 1 -maxdepth 1 -not \( -name 'en*' -or -name 'locale.alias' \) | xargs rm -rf
find /usr/local/share/locale -mindepth 1 -maxdepth 1 -not \( -name 'en*' -or -name 'locale.alias' \) | xargs rm -rf
rm -rf /usr/local/share/man


wget https://cmake.org/files/v3.15/cmake-3.15.7.tar.gz
tar zxf cmake-3.15.7.tar.gz
cd cmake-3.15.7
./bootstrap --prefix=/usr/local
make -j$(nproc)
make install
