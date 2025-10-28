#!/bin/bash

# Database functions
db_init() {
    mkdir -p "$DB_DIR"
    [[ -f "$DB_DIR/installed" ]] || touch "$DB_DIR/installed"
    [[ -f "$DB_DIR/available" ]] || touch "$DB_DIR/available"
    
    # Initialize cache database
    sqlite3 "$DB_DIR/build_cache.db" << EOF 2>/dev/null
        CREATE TABLE IF NOT EXISTS build_cache (
            pkgname TEXT,
            build_hash TEXT,
            result_path TEXT,
            timestamp INTEGER,
            PRIMARY KEY (pkgname, build_hash)
        );
EOF
}

db_add_installed() {
    local pkg="$1" version="$2" files_hash="$3"
    echo "$pkg $version $files_hash $(date +%s)" >> "$DB_DIR/installed"
}

db_remove_installed() {
    local pkg="$1"
    grep -v "^$pkg " "$DB_DIR/installed" > "$DB_DIR/installed.tmp" 2>/dev/null || true
    mv "$DB_DIR/installed.tmp" "$DB_DIR/installed"
}

# Dependency resolution
resolve_deps() {
    local pkgfile="$1"
    
    if [[ ! -f "$pkgfile" ]]; then
        echo "Error: Package file $pkgfile not found" >&2
        return 1
    fi
    
    # Source the pkgbuild in a subshell to extract dependencies
    (
        source "$pkgfile"
        echo "${depends[@]:-} ${makedepends[@]:-}"
    )
}

# Download source
download_source() {
    local url="$1" dest="$2"
    
    if [[ ! -f "$dest" ]]; then
        echo "Downloading: $url"
        curl $CURL_OPTS -L -o "$dest" "$url" || {
            echo "Error: Failed to download $url" >&2
            return 1
        }
    fi
}

# Build environment setup
setup_buildenv() {
    local pkg="$1" build_dir="$2"
    
    if [[ $USE_NAMESPACES -eq 1 ]] && unshare -Ur echo "test" >/dev/null 2>&1; then
        build_in_namespace "$pkg" "$build_dir"
    else
        echo "Warning: Namespaces not available, using simple chroot"
        build_in_chroot "$pkg" "$build_dir"
    fi
}

build_in_namespace() {
    local pkg="$1" build_dir="$2"
    local src_dir="$SOURCE_DIR/$pkg"
    
    # Create build directory
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    
    # Copy sources
    cp -r "$src_dir"/* "$build_dir/" 2>/dev/null || true
    
    # Build in namespace
    unshare -Urpmu -R "$build_dir" --mount-proc \
        sh -c "
            cd '/'
            mount -t tmpfs tmpfs '/build'
            cp -r /src/* /build/ 2>/dev/null || true
            cd '/build'
            build_package
        " || return 1
}

build_in_chroot() {
    local pkg="$1" build_dir="$2"
    local src_dir="$SOURCE_DIR/$pkg"
    
    # Simple chroot-like environment
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cp -r "$src_dir"/* "$build_dir/" 2>/dev/null || true
    
    (
        cd "$build_dir"
        build_package
    ) || return 1
}

# Checksum verification
verify_source() {
    local pkg="$1" pkgfile="$2"
    
    # Source pkgbuild to get sources and checksums
    source "$pkgfile"
    
    for i in "${!source[@]}"; do
        local src="${source[$i]}"
        local sum="${checksums[$i]}"
        local filename=$(basename "$src")
        local filepath="$SOURCE_DIR/$pkg/$filename"
        
        if [[ ! -f "$filepath" ]]; then
            echo "Error: Source file not found: $filename" >&2
            return 1
        fi
        
        case "$CHECKSUMS" in
            sha256)
                if ! echo "$sum  $filepath" | sha256sum -c - >/dev/null 2>&1; then
                    echo "Error: Checksum verification failed for $filename" >&2
                    return 1
                fi
                ;;
            md5)
                if ! echo "$sum  $filepath" | md5sum -c - >/dev/null 2>&1; then
                    echo "Error: Checksum verification failed for $filename" >&2
                    return 1
                fi
                ;;
        esac
    done
    
    echo "All source files verified"
}

# Build cache management
get_build_hash() {
    local pkgfile="$1"
    local dephash=$(resolve_deps "$pkgfile" | sha256sum | cut -d' ' -f1)
    local srchash=$(sha256sum "$pkgfile" | cut -d' ' -f1)
    echo "${dephash}:${srchash}" | sha256sum | cut -d' ' -f1
}

cache_store() {
    local pkg="$1" hash="$2" path="$3"
    sqlite3 "$DB_DIR/build_cache.db" \
        "INSERT OR REPLACE INTO build_cache VALUES ('$pkg', '$hash', '$path', strftime('%s','now'));"
}

cache_lookup() {
    local pkg="$1" hash="$2"
    sqlite3 "$DB_DIR/build_cache.db" \
        "SELECT result_path FROM build_cache WHERE pkgname='$pkg' AND build_hash='$hash';"
}

# Package installation
pkg_install() {
    local pkg_input="$1"
    local pkgfile=$(find_pkgfile "$pkg_input")
    
    if [[ -z "$pkgfile" ]]; then
        echo "Error: Package $pkg_input not found" >&2
        return 1
    fi
    
    local pkgname=$(basename "$pkgfile" .pkgbuild)
    echo "Installing $pkgname..."
    
    # Resolve and install dependencies
    local deps=$(resolve_deps "$pkgfile")
    for dep in $deps; do
        if ! is_installed "$dep"; then
            echo "Installing dependency: $dep"
            pkg_install "$dep"
        fi
    done
    
    # Build and install package
    pkg_build "$pkgfile"
    
    echo "Successfully installed $pkgname"
}

pkg_build() {
    local pkgfile="$1"
    local pkgname=$(basename "$pkgfile" .pkgbuild)
    local build_hash=$(get_build_hash "$pkgfile")
    local cache_result=$(cache_lookup "$pkgname" "$build_hash")
    
    # Check build cache
    if [[ -n "$cache_result" ]] && [[ -f "$cache_result" ]] && [[ $KEEP_BUILDDIR -eq 0 ]]; then
        echo "Using cached build for $pkgname"
        cp "$cache_result" "${PKG_DIR}/"
        return 0
    fi
    
    echo "Building $pkgname..."
    
    # Prepare sources
    local src_dir="$SOURCE_DIR/$pkgname"
    mkdir -p "$src_dir"
    
    source "$pkgfile"
    for src in "${source[@]}"; do
        local filename=$(basename "$src")
        download_source "$src" "$src_dir/$filename"
    done
    
    # Verify sources
    verify_source "$pkgname" "$pkgfile"
    
    # Fresh build
    local build_dir="${BUILD_DIR}/${pkgname}-build"
    
    # Define build_package function for sandbox
    build_package() {
        source "$pkgfile"
        
        # Extract sources
        for src in "${source[@]}"; do
            local filename=$(basename "$src")
            tar -xf "$filename" 2>/dev/null || true
        done
        
        # Find and enter source directory
        local srcdir=$(find . -maxdepth 1 -type d -name "*-*" | head -1)
        if [[ -n "$srcdir" ]]; then
            cd "$srcdir"
        fi
        
        # Run build function
        build
        
        # Run package function
        if type package >/dev/null 2>&1; then
            package
        fi
    }
    
    setup_buildenv "$pkgname" "$build_dir"
    
    # Create package archive
    local pkg_version="${pkgver:-1.0}-${pkgrel:-1}"
    local pkgfile_path="${PKG_DIR}/${pkgname}-${pkg_version}.pkg.tar.gz"
    
    (cd "$build_dir" && tar -czf "$pkgfile_path" .)
    
    # Cache the result
    cache_store "$pkgname" "$build_hash" "$pkgfile_path"
    
    echo "Build complete: $pkgfile_path"
}

pkg_remove() {
    local pkg="$1"
    
    if ! is_installed "$pkg"; then
        echo "Error: $pkg is not installed" >&2
        return 1
    fi
    
    echo "Removing $pkg..."
    db_remove_installed "$pkg"
    echo "Removed $pkg"
}

pkg_list() {
    if [[ ! -s "$DB_DIR/installed" ]]; then
        echo "No packages installed"
        return 0
    fi
    
    echo "Installed packages:"
    column -t "$DB_DIR/installed"
}

pkg_update() {
    echo "Updating package database..."
    # Placeholder for future repository update functionality
    echo "Package database updated"
}

# Helper functions
find_pkgfile() {
    local pkg_input="$1"
    
    # If it's already a file
    if [[ -f "$pkg_input" ]]; then
        echo "$pkg_input"
        return 0
    fi
    
    # Search in current directory and examples
    local found
    found=$(find . -name "$pkg_input.pkgbuild" -o -name "PKGBUILD.$pkg_input" | head -1)
    
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi
    
    # Search in examples directory
    if [[ -d "$SCRIPT_DIR/../examples" ]]; then
        found=$(find "$SCRIPT_DIR/../examples" -name "$pkg_input.pkgbuild" | head -1)
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
    fi
    
    return 1
}

is_installed() {
    local pkg="$1"
    grep -q "^$pkg " "$DB_DIR/installed" 2>/dev/null
}
