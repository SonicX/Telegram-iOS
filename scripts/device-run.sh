#!/bin/bash
#
# Сборка dev-версии Swiftgram и установка по кабелю на подключённый iPhone —
# без Xcode. Нужен для устройств, которые Xcode не видит (iPhone X на iOS 16
# под Xcode 27: «Pairing State: unsupported»).
#
# Подпись — development (build-system/configuration.json + codesigning-dev),
# устройство должно быть в dev-профиле. Ставится поверх TestFlight-версии с тем
# же bundle id, данные и вход сохраняются.
#
# Использование:
#   scripts/device-run.sh            — собрать debug_arm64 и установить
#   scripts/device-run.sh --logs     — то же + сразу открыть живые логи
#   SKIP_BUILD=1 scripts/device-run.sh   — только установить последний IPA
#
# Переменные окружения (опционально):
#   CONFIGURATION  — debug_arm64 (по умолчанию, быстрее пересборка) или release_arm64
#   DEVICE_UDID    — UDID телефона, если подключено несколько (idevice_id -l)
#   OVERRIDE_XCODE_VERSION — по умолчанию включено (локальный Xcode свежее проектного)
#
# Логи: scripts/device-logs.sh (см. там).
#
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${CONFIGURATION:-debug_arm64}"
ARTIFACTS_DIR="build/device-artifacts"
IPA="$ARTIFACTS_DIR/Swiftgram.ipa"

OPEN_LOGS=0
for arg in "$@"; do
  case "$arg" in
    --logs) OPEN_LOGS=1 ;;
    *) echo "Неизвестный аргумент: $arg"; exit 1 ;;
  esac
done

for tool in idevice_id ideviceinstaller; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Нет $tool. Установи: brew install libimobiledevice ideviceinstaller"
    exit 1
  fi
done

if [ -z "$DEVICE_UDID" ]; then
  DEVICES=($(idevice_id -l))
  if [ "${#DEVICES[@]}" = "0" ]; then
    echo "Телефон не найден. Подключи по кабелю, разблокируй и нажми «Доверять»."
    exit 1
  fi
  if [ "${#DEVICES[@]}" != "1" ]; then
    echo "Подключено несколько устройств, укажи DEVICE_UDID:"
    printf '  %s\n' "${DEVICES[@]}"
    exit 1
  fi
  DEVICE_UDID="${DEVICES[0]}"
fi
echo "Устройство: $DEVICE_UDID"

if [ -z "$SKIP_BUILD" ]; then
  MAKE_EXTRA_ARGS=()
  case "$(echo "${OVERRIDE_XCODE_VERSION:-1}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y) MAKE_EXTRA_ARGS+=(--overrideXcodeVersion) ;;
  esac
  OFFSET="$(cat build_number_offset 2>/dev/null || echo 0)"
  GIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
  BUILD_NUMBER="$((OFFSET + GIT_COUNT))"

  echo "Сборка $CONFIGURATION (build $BUILD_NUMBER)..."
  START=$(date +%s)
  python3 -u build-system/Make/Make.py "${MAKE_EXTRA_ARGS[@]}" build \
    --configurationPath=build-system/configuration.json \
    --codesigningInformationPath=build-system/codesigning-dev \
    --configuration="$CONFIGURATION" \
    --buildNumber="$BUILD_NUMBER" \
    --outputBuildArtifactsPath="$ARTIFACTS_DIR"
  echo "Сборка заняла $(( ($(date +%s) - START) / 60 )) мин."
fi

if [ ! -f "$IPA" ]; then
  echo "IPA не найден: $IPA"
  exit 1
fi

echo "Установка $IPA ..."
ideviceinstaller -u "$DEVICE_UDID" install "$IPA"
echo "Готово: приложение установлено. Запусти его на телефоне."

if [ "$OPEN_LOGS" = "1" ]; then
  exec "$REPO_ROOT/scripts/device-logs.sh"
fi
