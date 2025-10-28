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
