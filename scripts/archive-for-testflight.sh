#!/bin/bash
#
# Сборка Swiftgram для TestFlight / App Store.
#
# Подпись и профили берутся ВСЕГДА из репозитория — спрашивать ничего не нужно:
#   - сертификат (distribution .p12) и App Store профили: build-system/codesigning
#   - App Store конфигурация (bundle_id, team_id, is_appstore_build=true):
#     build-system/appstore-configuration.json
#
# Состав сборки определяется Telegram/BUILD: основное приложение + расширение
# уведомлений (NotificationService). Прочие расширения отключены, потому что для
# них нет distribution-профилей.
#
# Результат: build/artifacts/Swiftgram.ipa и build/artifacts/Swiftgram.DSYMs.zip
#
# Использование:
#   sh scripts/archive-for-testflight.sh
#
# Переменные окружения (все опциональны — по умолчанию всё уже настроено):
#   BUILD_NUMBER           — номер сборки (по умолчанию: build_number_offset + git rev-list --count HEAD)
#   CONFIGURATION_PATH     — путь к configuration.json (по умолчанию: build-system/appstore-configuration.json)
#   CODESIGNING_PATH       — каталог с профилями и сертификатами (по умолчанию: build-system/codesigning)
#   CACHE_DIR              — каталог кэша Bazel
#   CREATE_ZIP            — если 1/true/yes, создаёт Swiftgram-TestFlight-<дата>-<build>.zip
#   OVERRIDE_XCODE_VERSION — по умолчанию ВКЛЮЧЕНО; поставь 0/false, чтобы требовать точную версию Xcode
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

# Проверяем, что нужные App Store профили на месте (приложение + уведомления).
MISSING_PROFILE=0
for required in Telegram_Store.mobileprovision TelegramNotification_Store.mobileprovision; do
  if [ ! -f "$CODESIGNING_PATH/profiles/$required" ]; then
    echo "Ошибка: не найден профиль $CODESIGNING_PATH/profiles/$required"
    MISSING_PROFILE=1
  fi
done
if [ "$MISSING_PROFILE" != "0" ]; then
  echo "Положи недостающие App Store distribution профили в $CODESIGNING_PATH/profiles и повтори."
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
echo "Подпись:      $CODESIGNING_PATH (Telegram_Store + TelegramNotification_Store)"
echo "Номер сборки: $BUILD_NUMBER"
echo "Артефакты:    $ARTIFACTS_DIR"
echo ""

mkdir -p "$ARTIFACTS_DIR"

# --overrideXcodeVersion включён по умолчанию: версия Xcode на машине обычно
# свежее зафиксированной в проекте; поставь OVERRIDE_XCODE_VERSION=0 для строгой проверки.
MAKE_EXTRA_ARGS=()
case "$(echo "${OVERRIDE_XCODE_VERSION:-1}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|y) MAKE_EXTRA_ARGS+=(--overrideXcodeVersion) ;;
esac

# ВНИМАНИЕ: НЕ передаём --disableExtensions — состав расширений задаётся в
# Telegram/BUILD (сейчас: только NotificationService), чтобы пуши работали.
MAKE_ARGS=(
  build
  --configurationPath="$CONFIGURATION_PATH"
  --codesigningInformationPath="$CODESIGNING_PATH"
  --configuration=release_arm64
  --buildNumber="$BUILD_NUMBER"
  --outputBuildArtifactsPath="$ARTIFACTS_DIR"
)

if [ -n "$CACHE_DIR" ]; then
  MAKE_EXTRA_ARGS+=(--cacheDir="$CACHE_DIR")
fi

python3 build-system/Make/Make.py "${MAKE_EXTRA_ARGS[@]}" "${MAKE_ARGS[@]}"

echo ""
echo "Сборка завершена."
echo "  IPA:   $ARTIFACTS_DIR/Swiftgram.ipa"
echo "  DSYMs: $ARTIFACTS_DIR/Swiftgram.DSYMs.zip"
echo ""
echo "Загрузка в TestFlight: перетащи IPA в Transporter,"
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
