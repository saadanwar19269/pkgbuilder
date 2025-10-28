# pkgbuilder - Local AUR-like Package Builder

A lightweight, secure package builder that compiles software from source with dependency resolution, build caching, and sandboxed builds.

## Features

- **Dependency Resolution**: Automatically handles dependencies
- **Build Caching**: Skip recompilation with hash-based caching
- **Sandboxed Builds**: Uses Linux namespaces for safe building
- **Signature Verification**: Checksum verification for source files
- **Reproducible Builds**: Consistent build environments
- **Web UI**: Browse packages via web interface (optional)

## Quick Install

git clone https://github.com/yourusername/pkgbuilder

cd pkgbuilder

./install.sh

# Usage

**Install a package**

pkgbuilder install example

**Build without installing**

pkgbuilder build example

**List installed packages**

pkgbuilder list

**Remove a package**

pkgbuilder remove example

**Start web UI**

pkgbuilder-webui

# Creating Packages

Create a .pkgbuild file:


pkgname="example"
pkgver="1.0.0"
source=("https://example.com/$pkgname-$pkgver.tar.gz")
checksums=("sha256:...")
depends=("zlib")

build() {
    ./configure --prefix="$pkgdir/$PREFIX"
    make
}

package() {
    make install
}

# Requirements

bash, make, gcc, jq, sqlite3
unshare (for sandboxing)
