#!/bin/bash
#
# Сборка архива Swiftgram для выкладки в TestFlight.
# Результат: build/artifacts/Swiftgram.ipa, build/artifacts/Swiftgram.DSYMs.zip
# и опционально build/artifacts/Swiftgram-TestFlight-<дата>-<build>.zip
#
# Требования:
# - App Store distribution provisioning profiles и сертификаты в --codesigningInformationPath
# - Конфигурация в build-system/appstore-configuration.json (bundle_id, team_id и т.д.)
#
# Переменные окружения (опционально):
#   BUILD_NUMBER     — номер сборки (по умолчанию: build_number_offset + git rev-list --count HEAD)
#   CONFIGURATION_PATH — путь к configuration.json (по умолчанию: build-system/appstore-configuration.json)
#   CODESIGNING_PATH   — каталог с профилями и сертификатами (по умолчанию: build-system/codesigning)
#   CACHE_DIR        — каталог кэша Bazel (например $HOME/telegram-bazel-cache)
#   CREATE_ZIP      — если не пусто, создаёт Swiftgram-TestFlight-<date>-<build>.zip (1, true, yes)
#   OVERRIDE_XCODE_VERSION — использовать установленную версию Xcode (1, true, yes), если версия в проекте не совпадает
#

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION_PATH="${CONFIGURATION_PATH:-build-system/appstore-configuration.json}"
CODESIGNING_PATH="${CODESIGNING_PATH:-build-system/codesigning}"
ARTIFACTS_DIR="build/artifacts"

if [ ! -f "$CONFIGURATION_PATH" ]; then
  echo "Ошибка: конфигурация не найдена: $CONFIGURATION_PATH"
  exit 1
fi

if [ ! -d "$CODESIGNING_PATH" ]; then
  echo "Ошибка: каталог подписей не найден: $CODESIGNING_PATH"
  echo "Для TestFlight нужны App Store distribution профили и сертификаты."
  exit 1
fi

if [ -n "$BUILD_NUMBER" ]; then
  BUILD_NUMBER="$BUILD_NUMBER"
else
  OFFSET="$(cat build_number_offset 2>/dev/null || echo 0)"
  GIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
  BUILD_NUMBER="$((OFFSET + GIT_COUNT))"
fi

echo "Конфигурация: $CONFIGURATION_PATH"
echo "Подпись:      $CODESIGNING_PATH"
echo "Номер сборки: $BUILD_NUMBER"
echo "Артефакты:    $ARTIFACTS_DIR"
echo ""

mkdir -p "$ARTIFACTS_DIR"

MAKE_EXTRA_ARGS=()
MAKE_ARGS=(
  build
  --configurationPath="$CONFIGURATION_PATH"
  --codesigningInformationPath="$CODESIGNING_PATH"
  --configuration=release_arm64
  --buildNumber="$BUILD_NUMBER"
  --outputBuildArtifactsPath="$ARTIFACTS_DIR"
  --disableExtensions
)

if [ -n "$CACHE_DIR" ]; then
  MAKE_EXTRA_ARGS+=(--cacheDir="$CACHE_DIR")
fi
if [ -n "$OVERRIDE_XCODE_VERSION" ]; then
  case "$(echo "$OVERRIDE_XCODE_VERSION" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y) MAKE_EXTRA_ARGS+=(--overrideXcodeVersion) ;;
  esac
fi

python3 build-system/Make/Make.py "${MAKE_EXTRA_ARGS[@]}" "${MAKE_ARGS[@]}"

echo ""
echo "Сборка завершена."
echo "  IPA:   $ARTIFACTS_DIR/Swiftgram.ipa"
echo "  DSYMs: $ARTIFACTS_DIR/Swiftgram.DSYMs.zip"
echo ""
echo "Загрузка в TestFlight: Xcode → Window → Organizer → Distribute App → App Store Connect,"
echo "или: xcrun altool --upload-app --type ios --file $ARTIFACTS_DIR/Swiftgram.ipa --username <Apple ID> --password <app-specific password>"
echo ""

if [ -n "$CREATE_ZIP" ] && [ "$CREATE_ZIP" != "0" ]; then
  case "$(echo "$CREATE_ZIP" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y)
      ZIP_NAME="Swiftgram-TestFlight-$(date +%Y%m%d)-${BUILD_NUMBER}.zip"
      ZIP_PATH="$ARTIFACTS_DIR/$ZIP_NAME"
      (cd "$ARTIFACTS_DIR" && zip -r "$ZIP_NAME" Swiftgram.ipa Swiftgram.DSYMs.zip)
      echo "Архив для выкладки: $ZIP_PATH"
      ;;
  esac
fi
