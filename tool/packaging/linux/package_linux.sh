#!/usr/bin/env bash
# Package TallyIsle Linux x64 release bundle into:
#   - TallyIsle-Linux-x64-portable.tar.gz
#   - TallyIsle-Linux-x64.deb
#   - TallyIsle-Linux-x64.rpm
#   - TallyIsle-Linux-x64.AppImage
#   - TallyIsle-Linux-x64.flatpak
#
# Usage:
#   bash tool/packaging/linux/package_linux.sh \
#     [--bundle-dir build/linux/x64/release/bundle] \
#     [--out-dir .] \
#     [--formats tar.gz,deb,rpm,appimage,flatpak]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PUBSPEC="$REPO_ROOT/pubspec.yaml"
ICON_DIR="$REPO_ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
APP_ID="com.tallyisle.app"

BUNDLE_DIR="$REPO_ROOT/build/linux/x64/release/bundle"
OUT_DIR="$REPO_ROOT"
FORMATS="tar.gz,deb,rpm,appimage,flatpak"

usage() {
  cat <<EOF
Usage: bash tool/packaging/linux/package_linux.sh [options]
  --bundle-dir <dir>   Path to flutter build linux release bundle (default: build/linux/x64/release/bundle)
  --out-dir <dir>      Output directory for installers (default: repo root)
  --formats <csv>      Comma-separated subset of: tar.gz,deb,rpm,appimage,flatpak
  --help               Show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --formats)
      FORMATS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$PUBSPEC" ]]; then
  echo "error: pubspec.yaml not found at $PUBSPEC" >&2
  exit 1
fi

PUBSPEC_VERSION="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$PUBSPEC" | head -n1 | tr -d '\r')"
if [[ -z "$PUBSPEC_VERSION" || "$PUBSPEC_VERSION" != *+* ]]; then
  echo "error: failed to parse version: X.Y.Z+BUILD from $PUBSPEC (got '$PUBSPEC_VERSION')" >&2
  exit 1
fi

APP_VERSION="${PUBSPEC_VERSION%%+*}"
BUILD_NUMBER="${PUBSPEC_VERSION##*+}"

if ! [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid semantic version '$APP_VERSION'" >&2
  exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: invalid build number '$BUILD_NUMBER'" >&2
  exit 1
fi

BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

if [[ ! -f "$BUNDLE_DIR/tallyisle" ]]; then
  echo "error: expected executable '$BUNDLE_DIR/tallyisle' not found" >&2
  exit 1
fi

ICON_SIZES=(16 32 64 128 256 512)
for size in "${ICON_SIZES[@]}"; do
  if [[ ! -f "$ICON_DIR/app_icon_${size}.png" ]]; then
    echo "error: missing icon '$ICON_DIR/app_icon_${size}.png'" >&2
    exit 1
  fi
done

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$SCRIPT_DIR/${APP_ID}.desktop"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

has_format() {
  local target="$1"
  [[ ",$FORMATS," == *",$target,"* ]]
}

assert_nonempty() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "error: expected non-empty artifact '$path'" >&2
    exit 1
  fi
  ls -lh "$path"
}

echo "Packaging TallyIsle ${APP_VERSION}+${BUILD_NUMBER} (Linux x64)"
echo "  bundle : $BUNDLE_DIR"
echo "  out    : $OUT_DIR"
echo "  formats: $FORMATS"

# 1. Portable tar.gz
if has_format "tar.gz"; then
  TAR_OUT="$OUT_DIR/TallyIsle-Linux-x64-portable.tar.gz"
  tar -C "$BUNDLE_DIR" -czf "$TAR_OUT" .
  assert_nonempty "$TAR_OUT"
fi

# 2. Debian / Ubuntu .deb
if has_format "deb"; then
  DEB_STAGE="$WORK_DIR/deb"
  DEB_OUT="$OUT_DIR/TallyIsle-Linux-x64.deb"

  mkdir -p \
    "$DEB_STAGE/DEBIAN" \
    "$DEB_STAGE/opt/tallyisle" \
    "$DEB_STAGE/usr/bin" \
    "$DEB_STAGE/usr/share/applications" \
    "$DEB_STAGE/usr/share/metainfo" \
    "$DEB_STAGE/usr/share/mime/packages"

  cp -a "$BUNDLE_DIR/." "$DEB_STAGE/opt/tallyisle/"
  chmod +x "$DEB_STAGE/opt/tallyisle/tallyisle"
  ln -sf /opt/tallyisle/tallyisle "$DEB_STAGE/usr/bin/tallyisle"

  install -Dm644 "$SCRIPT_DIR/${APP_ID}.desktop" \
    "$DEB_STAGE/usr/share/applications/${APP_ID}.desktop"
  install -Dm644 "$SCRIPT_DIR/${APP_ID}.metainfo.xml" \
    "$DEB_STAGE/usr/share/metainfo/${APP_ID}.metainfo.xml"
  install -Dm644 "$SCRIPT_DIR/${APP_ID}.mime.xml" \
    "$DEB_STAGE/usr/share/mime/packages/${APP_ID}.mime.xml"

  for size in "${ICON_SIZES[@]}"; do
    install -Dm644 "$ICON_DIR/app_icon_${size}.png" \
      "$DEB_STAGE/usr/share/icons/hicolor/${size}x${size}/apps/${APP_ID}.png"
  done

  INSTALLED_SIZE_KB="$(du -sk "$DEB_STAGE/opt" "$DEB_STAGE/usr" | awk '{sum+=$1} END {print sum+0}')"

  cat > "$DEB_STAGE/DEBIAN/control" <<EOF
Package: tallyisle
Version: ${APP_VERSION}-${BUILD_NUMBER}
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: ${INSTALLED_SIZE_KB}
Maintainer: TallyIsle <support@tallyisle.com>
Homepage: https://github.com/tallyisle/tallyisle
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, xdg-utils
Description: TallyIsle - Local-first personal accounting and asset manager
 Local-first, cent-accurate personal accounting and asset manager built with Flutter.
EOF

  cat > "$DEB_STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database /usr/share/mime >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
EOF

  cat > "$DEB_STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database /usr/share/mime >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
EOF

  chmod 0755 "$DEB_STAGE/DEBIAN" "$DEB_STAGE/DEBIAN/postinst" "$DEB_STAGE/DEBIAN/postrm"
  chmod 0644 "$DEB_STAGE/DEBIAN/control"

  dpkg-deb --build --root-owner-group "$DEB_STAGE" "$DEB_OUT"
  assert_nonempty "$DEB_OUT"
fi

# 3. Fedora / RHEL / openSUSE .rpm
if has_format "rpm"; then
  RPM_TOP="$WORK_DIR/rpmbuild"
  RPM_OUT="$OUT_DIR/TallyIsle-Linux-x64.rpm"
  mkdir -p "$RPM_TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

  cat > "$RPM_TOP/SPECS/tallyisle.spec" <<EOF
%define _build_id_links none
%define debug_package %{nil}
%define __os_install_post %{nil}
AutoReqProv: no

Name:           tallyisle
Version:        ${APP_VERSION}
Release:        ${BUILD_NUMBER}
Summary:        TallyIsle - Local-first personal accounting and asset manager
License:        PolyForm-Noncommercial-1.0.0
URL:            https://github.com/tallyisle/tallyisle
BuildArch:      x86_64
Requires:       gtk3, glib2, xdg-utils

%description
TallyIsle is a local-first, cent-accurate personal accounting and asset manager.

%install
mkdir -p %{buildroot}/opt/tallyisle
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/metainfo
mkdir -p %{buildroot}/usr/share/mime/packages
cp -a "${BUNDLE_DIR}/." %{buildroot}/opt/tallyisle/
chmod +x %{buildroot}/opt/tallyisle/tallyisle
ln -sf /opt/tallyisle/tallyisle %{buildroot}/usr/bin/tallyisle
install -Dm644 "${SCRIPT_DIR}/${APP_ID}.desktop" %{buildroot}/usr/share/applications/${APP_ID}.desktop
install -Dm644 "${SCRIPT_DIR}/${APP_ID}.metainfo.xml" %{buildroot}/usr/share/metainfo/${APP_ID}.metainfo.xml
install -Dm644 "${SCRIPT_DIR}/${APP_ID}.mime.xml" %{buildroot}/usr/share/mime/packages/${APP_ID}.mime.xml
for s in 16 32 64 128 256 512; do
  install -Dm644 "${ICON_DIR}/app_icon_\${s}.png" "%{buildroot}/usr/share/icons/hicolor/\${s}x\${s}/apps/${APP_ID}.png"
done

%post
update-desktop-database -q /usr/share/applications 2>/dev/null || true
update-mime-database /usr/share/mime >/dev/null 2>&1 || true
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

%postun
update-desktop-database -q /usr/share/applications 2>/dev/null || true
update-mime-database /usr/share/mime >/dev/null 2>&1 || true
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

%files
/opt/tallyisle
/usr/bin/tallyisle
/usr/share/applications/${APP_ID}.desktop
/usr/share/metainfo/${APP_ID}.metainfo.xml
/usr/share/mime/packages/${APP_ID}.mime.xml
/usr/share/icons/hicolor/*/apps/${APP_ID}.png
EOF

  rpmbuild -bb --define "_topdir $RPM_TOP" "$RPM_TOP/SPECS/tallyisle.spec"
  BUILT_RPM="$(find "$RPM_TOP/RPMS" -name '*.rpm' | head -n1)"
  if [[ -z "$BUILT_RPM" || ! -f "$BUILT_RPM" ]]; then
    echo "error: rpmbuild produced no .rpm file" >&2
    exit 1
  fi
  cp "$BUILT_RPM" "$RPM_OUT"
  assert_nonempty "$RPM_OUT"
fi

# 4. Universal Linux AppImage
if has_format "appimage"; then
  APPDIR="$WORK_DIR/TallyIsle.AppDir"
  APPIMAGE_OUT="$OUT_DIR/TallyIsle-Linux-x64.AppImage"
  APPIMAGETOOL="$WORK_DIR/appimagetool-x86_64.AppImage"

  mkdir -p \
    "$APPDIR/usr/opt/tallyisle" \
    "$APPDIR/usr/bin" \
    "$APPDIR/usr/share/applications" \
    "$APPDIR/usr/share/metainfo" \
    "$APPDIR/usr/share/mime/packages"

  cp -a "$BUNDLE_DIR/." "$APPDIR/usr/opt/tallyisle/"
  chmod +x "$APPDIR/usr/opt/tallyisle/tallyisle"
  ln -sf ../opt/tallyisle/tallyisle "$APPDIR/usr/bin/tallyisle"

  install -Dm644 "$SCRIPT_DIR/${APP_ID}.desktop" \
    "$APPDIR/usr/share/applications/${APP_ID}.desktop"
  install -Dm644 "$SCRIPT_DIR/${APP_ID}.metainfo.xml" \
    "$APPDIR/usr/share/metainfo/${APP_ID}.metainfo.xml"
  install -Dm644 "$SCRIPT_DIR/${APP_ID}.mime.xml" \
    "$APPDIR/usr/share/mime/packages/${APP_ID}.mime.xml"

  for size in "${ICON_SIZES[@]}"; do
    install -Dm644 "$ICON_DIR/app_icon_${size}.png" \
      "$APPDIR/usr/share/icons/hicolor/${size}x${size}/apps/${APP_ID}.png"
  done

  install -Dm644 "$SCRIPT_DIR/${APP_ID}.desktop" "$APPDIR/${APP_ID}.desktop"
  install -Dm644 "$ICON_DIR/app_icon_256.png" "$APPDIR/${APP_ID}.png"
  ln -sf "${APP_ID}.png" "$APPDIR/.DirIcon"

  cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/opt/tallyisle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/opt/tallyisle/tallyisle" "$@"
EOF
  chmod +x "$APPDIR/AppRun"

  curl -fSL --retry 3 \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" \
    -o "$APPIMAGETOOL"
  chmod +x "$APPIMAGETOOL"

  APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 \
    "$APPIMAGETOOL" --no-appstream "$APPDIR" "$APPIMAGE_OUT"
  chmod +x "$APPIMAGE_OUT"
  assert_nonempty "$APPIMAGE_OUT"
fi

# 5. Flatpak single-file bundle
if has_format "flatpak"; then
  FLATPAK_REPO="$WORK_DIR/flatpak-repo"
  FLATPAK_BUILD="$WORK_DIR/flatpak-build"
  FLATPAK_OUT="$OUT_DIR/TallyIsle-Linux-x64.flatpak"

  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user -y --noninteractive flathub org.gnome.Platform//47 org.gnome.Sdk//47

  flatpak-builder --user --force-clean --disable-rofiles-fuse \
    --repo="$FLATPAK_REPO" \
    "$FLATPAK_BUILD" \
    "$SCRIPT_DIR/${APP_ID}.flatpak.json"

  flatpak build-bundle "$FLATPAK_REPO" "$FLATPAK_OUT" "$APP_ID"
  assert_nonempty "$FLATPAK_OUT"
fi

echo "Linux packaging completed successfully."
