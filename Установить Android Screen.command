#!/bin/bash
set -euo pipefail

# Android Screen 2.3.2 — self-contained installation for macOS.
# Downloads third-party tools only from their official distribution endpoints.

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES="$BASE_DIR/Исходники"
APP_PARENT="$HOME/Applications"
APP_TARGET="$APP_PARENT/Android Screen.app"
BUILD_DIR="$(/usr/bin/mktemp -d -t AndroidScreen.XXXXXXXX)"
BUILD_APP="$BUILD_DIR/Android Screen.app"
TOOLS="$BUILD_APP/Contents/Resources/Tools"
TOOLS_PREVIOUS="$APP_TARGET/Contents/Resources/Tools"
SCRCPY_VERSION="5.0.1"

cleanup() { /bin/rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

say() { /bin/echo "$*"; }
fail() {
    say ""
    say "ОШИБКА: $*"
    say ""
    read -r -p "Нажми Enter, чтобы закрыть установщик... " _ || true
    exit 1
}

say "Android Screen 2.3.2 — установка для macOS"
say "=========================================="
say "Приложение и его инструменты будут размещены в:"
say "  $APP_TARGET"
say ""

[ -f "$SOURCES/AndroidScreen.swift" ] || fail "Отсутствует Исходники/AndroidScreen.swift. Распакуй архив полностью."
[ -d "$SOURCES/AndroidScreen.iconset" ] || fail "Отсутствует Исходники/AndroidScreen.iconset."
[ -f "$SOURCES/AndroidScreen.png" ] || fail "Отсутствует Исходники/AndroidScreen.png."

ARCH="$(/usr/bin/uname -m)"
case "$ARCH" in
    arm64)
        SCRCPY_RELEASE_ARCH="aarch64"
        SCRCPY_SHA256="33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b"
        ;;
    x86_64)
        SCRCPY_RELEASE_ARCH="x86_64"
        SCRCPY_SHA256="31a5467a9e907f162b093267cbbab1276b15c6e709c2ea8159566a8d165beb50"
        ;;
    *) fail "Неподдерживаемая архитектура macOS: $ARCH" ;;
esac
TARGET="${ARCH}-apple-macosx12.0"
SCRCPY_DIR="scrcpy-macos-${SCRCPY_RELEASE_ARCH}-v${SCRCPY_VERSION}"
SCRCPY_URL="https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/${SCRCPY_DIR}.tar.gz"
ADB_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"

say "1/7. Проверяю инструменты Apple (Swift + macOS SDK)..."
if ! SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc 2>/dev/null)" || [ ! -x "$SWIFTC" ]; then
    say "Command Line Tools не обнаружены. Запрашиваю штатную установку Apple..."
    /usr/bin/xcode-select --install || true
    fail "Заверши установку Apple Command Line Tools и запусти установщик снова. Этот системный компонент нельзя установить внутрь приложения."
fi
if ! SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || [ ! -d "$SDK/System/Library/Frameworks" ]; then
    say "macOS SDK не найден или не работает. Запрашиваю установку Apple Command Line Tools..."
    /usr/bin/xcode-select --install || true
    fail "Дождись завершения установки или исправь Xcode/Command Line Tools, затем запусти установщик повторно."
fi
[ -x /usr/bin/iconutil ] || fail "Не найден системный iconutil."
[ -x /usr/bin/codesign ] || fail "Не найден системный codesign."
[ -x /usr/bin/curl ] || fail "Не найден системный curl."
[ -x /usr/bin/unzip ] || fail "Не найден системный unzip."
[ -x /usr/bin/shasum ] || fail "Не найден системный shasum."
say "  Swift: $SWIFTC"
say "  SDK:   $SDK"
say "  Mac:   $ARCH"

say ""
say "2/7. Проверяю, работает ли компилятор..."
printf 'print("SWIFT_OK")\n' > "$BUILD_DIR/smoke.swift"
if ! "$SWIFTC" -sdk "$SDK" -target "$TARGET" -swift-version 5 \
    "$BUILD_DIR/smoke.swift" -o "$BUILD_DIR/swift-smoke" > "$BUILD_DIR/check.log" 2>&1; then
    /bin/cat "$BUILD_DIR/check.log"
    fail "Swift/SDK не может скомпилировать тестовую программу. Проверь установку Apple Command Line Tools."
fi

/bin/mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources" "$TOOLS"

say ""
say "3/7. Собираю Android Screen (SwiftUI)..."
if ! "$SWIFTC" -sdk "$SDK" -target "$TARGET" -swift-version 5 -O -parse-as-library \
    -framework SwiftUI -framework AppKit \
    -o "$BUILD_APP/Contents/MacOS/AndroidScreen" \
    "$SOURCES/AndroidScreen.swift" > "$BUILD_DIR/build.log" 2>&1; then
    /bin/cat "$BUILD_DIR/build.log"
    fail "Swift не смог собрать Android Screen. Пришли текст ошибки из Терминала."
fi
/bin/chmod 755 "$BUILD_APP/Contents/MacOS/AndroidScreen"

say ""
say "4/7. Проверяю локальные утилиты scrcpy и adb..."

# A complete scrcpy release is required (the 'scrcpy-server' must match the client).
if [ -x "$TOOLS_PREVIOUS/scrcpy/scrcpy" ] && [ -f "$TOOLS_PREVIOUS/scrcpy/scrcpy-server" ]; then
    say "  scrcpy: найден в прежней версии Android Screen; переношу внутрь новой."
    /bin/cp -R "$TOOLS_PREVIOUS/scrcpy" "$TOOLS/scrcpy" || fail "Не удалось перенести встроенный scrcpy."
fi
if [ -x "$TOOLS_PREVIOUS/platform-tools/adb" ]; then
    say "  adb: найден в прежней версии Android Screen; переношу внутрь новой."
    /bin/cp -R "$TOOLS_PREVIOUS/platform-tools" "$TOOLS/platform-tools" || fail "Не удалось перенести встроенный adb."
fi

if [ ! -x "$TOOLS/scrcpy/scrcpy" ] || [ ! -f "$TOOLS/scrcpy/scrcpy-server" ]; then
    say "  scrcpy: встроенной копии нет — скачиваю версию $SCRCPY_VERSION для $ARCH ($SCRCPY_RELEASE_ARCH)."
    say "  Источник: $SCRCPY_URL"
    ARCHIVE="$BUILD_DIR/$SCRCPY_DIR.tar.gz"
    if ! /usr/bin/curl --fail --location --retry 3 --retry-delay 2 \
        --connect-timeout 20 --max-time 600 --output "$ARCHIVE" "$SCRCPY_URL"; then
        fail "Не удалось скачать scrcpy с GitHub. Проверь интернет/VPN и повтори установку. Ссылка: $SCRCPY_URL"
    fi
    ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{ print $1 }')"
    [ "$ACTUAL_SHA" = "$SCRCPY_SHA256" ] || fail "SHA-256 scrcpy не совпадает с опубликованной разработчиками контрольной суммой. Ничего не установлено."
    /bin/mkdir -p "$BUILD_DIR/scrcpy-extract"
    if ! /usr/bin/tar -xzf "$ARCHIVE" -C "$BUILD_DIR/scrcpy-extract"; then
        fail "Не удалось распаковать официальный архив scrcpy."
    fi
    if [ ! -x "$BUILD_DIR/scrcpy-extract/$SCRCPY_DIR/scrcpy" ] || \
       [ ! -f "$BUILD_DIR/scrcpy-extract/$SCRCPY_DIR/scrcpy-server" ]; then
        fail "В архиве scrcpy отсутствует программа или scrcpy-server."
    fi
    /bin/mv "$BUILD_DIR/scrcpy-extract/$SCRCPY_DIR" "$TOOLS/scrcpy"
    say "  scrcpy: загружен и проверен по SHA-256."
fi

if [ ! -x "$TOOLS/platform-tools/adb" ]; then
    say ""
    say "  adb: встроенной копии нет — требуется Android SDK Platform-Tools от Google."
    say "  Официальная страница и условия:"
    say "  https://developer.android.com/tools/releases/platform-tools"
    say "  Google распространяет SDK Platform-Tools по условиям Android SDK License Agreement."
    read -r -p "  Ты ознакомился с условиями Google и принимаешь их? [да/нет]: " ACCEPT_LICENSE || true
    case "$ACCEPT_LICENSE" in
        да|Да|ДА|yes|YES|Yes|y|Y|д|Д) ;;
        *) fail "Установка adb не разрешена. Приложение не заменено. Прими условия Google и запусти установщик снова." ;;
    esac
    ADB_ARCHIVE="$BUILD_DIR/platform-tools-darwin.zip"
    say "  Скачиваю официальную сборку Google..."
    if ! /usr/bin/curl --fail --location --retry 3 --retry-delay 2 \
        --connect-timeout 20 --max-time 600 --output "$ADB_ARCHIVE" "$ADB_URL"; then
        fail "Не удалось скачать ADB с Google. Проверь интернет и повтори установку. Ссылка: $ADB_URL"
    fi
    if ! /usr/bin/unzip -tq "$ADB_ARCHIVE" > "$BUILD_DIR/unzip-check.log" 2>&1; then
        /bin/cat "$BUILD_DIR/unzip-check.log"
        fail "Скачанный архив Platform-Tools повреждён."
    fi
    /bin/mkdir -p "$BUILD_DIR/adb-extract"
    if ! /usr/bin/unzip -q "$ADB_ARCHIVE" -d "$BUILD_DIR/adb-extract"; then
        fail "Не удалось распаковать Android Platform-Tools."
    fi
    if [ ! -f "$BUILD_DIR/adb-extract/platform-tools/adb" ]; then
        fail "В архиве Google не найден platform-tools/adb."
    fi
    /bin/mv "$BUILD_DIR/adb-extract/platform-tools" "$TOOLS/platform-tools"
    /bin/chmod 755 "$TOOLS/platform-tools/adb"
    say "  adb: загружен с Google, архив проверен на целостность."
fi

if ! "$TOOLS/scrcpy/scrcpy" --version > "$BUILD_DIR/scrcpy-version.log" 2>&1; then
    /bin/cat "$BUILD_DIR/scrcpy-version.log"
    fail "Встроенный scrcpy не запускается на этом Mac. Установка прервана."
fi
if ! "$TOOLS/platform-tools/adb" version > "$BUILD_DIR/adb-version.log" 2>&1; then
    /bin/cat "$BUILD_DIR/adb-version.log"
    fail "Встроенный adb не запускается на этом Mac. Установка прервана."
fi
say "  scrcpy: проверен запуск."
say "  adb:    проверен запуск."

say ""
say "5/7. Добавляю иконку и сведения о приложении..."
if ! /usr/bin/iconutil -c icns "$SOURCES/AndroidScreen.iconset" \
    -o "$BUILD_APP/Contents/Resources/AndroidScreen.icns"; then
    fail "Не удалось собрать иконку."
fi
/bin/cp "$SOURCES/AndroidScreen.png" "$BUILD_APP/Contents/Resources/AndroidScreen.png"
/bin/cat > "$BUILD_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
<key>CFBundleExecutable</key><string>AndroidScreen</string>
<key>CFBundleIdentifier</key><string>app.androidscreen.scrcpylauncher</string>
<key>CFBundleName</key><string>Android Screen</string>
<key>CFBundleDisplayName</key><string>Android Screen</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AndroidScreen.icns</string>
<key>CFBundleShortVersionString</key><string>2.3.2</string>
<key>CFBundleVersion</key><string>232</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Unofficial launcher for open-source scrcpy.</string>
</dict></plist>
PLIST
if ! /usr/bin/plutil -lint "$BUILD_APP/Contents/Info.plist"; then
    fail "Info.plist не прошёл проверку."
fi

say ""
say "6/7. Подписываю приложение локальной подписью..."
# Sign the included command-line binaries first, then seal the whole application.
for TOOL_BIN in "$TOOLS/scrcpy/scrcpy" "$TOOLS/platform-tools/adb"; do
    if ! /usr/bin/codesign --force --sign - --timestamp=none "$TOOL_BIN"; then
        fail "Не удалось локально подписать $TOOL_BIN"
    fi
done
if ! /usr/bin/codesign --force --sign - --timestamp=none "$BUILD_APP"; then
    fail "Не удалось локально подписать Android Screen."
fi
if ! /usr/bin/codesign --verify "$BUILD_APP"; then
    fail "Проверка подписи приложения не пройдена."
fi

say ""
say "7/7. Устанавливаю Android Screen (прошлая версия будет сохранена)..."
/bin/mkdir -p "$APP_PARENT"
BACKUP=""
if [ -e "$APP_TARGET" ]; then
    BACKUP="$APP_PARENT/Android Screen.backup.$(/bin/date '+%Y%m%d-%H%M%S')-$$.app"
    if ! /bin/mv "$APP_TARGET" "$BACKUP"; then
        fail "Не удалось создать резервную копию. Закрой Android Screen и повтори установку."
    fi
    say "  Резервная копия: $BACKUP"
fi
if ! /bin/mv "$BUILD_APP" "$APP_TARGET"; then
    if [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then
        /bin/mv "$BACKUP" "$APP_TARGET" || true
    fi
    fail "Ошибка установки. Предыдущая версия восстановлена, если она существовала."
fi

say ""
say "ГОТОВО! Android Screen 2.3.2 установлен:"
say "  $APP_TARGET"
say ""
say "Встроенные утилиты:"
say "  $APP_TARGET/Contents/Resources/Tools/scrcpy/scrcpy"
say "  $APP_TARGET/Contents/Resources/Tools/platform-tools/adb"
say ""
say "Homebrew не требуется. Скрипт не изменял системные копии scrcpy и adb."
say "IP, порт и альтернативный путь к scrcpy настраиваются через интерфейс приложения."
say ""
/usr/bin/open -R "$APP_TARGET" || true
read -r -p "Нажми Enter, чтобы закрыть установщик... " _ || true
