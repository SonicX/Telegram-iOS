#!/bin/bash
#
# Генерация Xcode-проекта Swiftgram с development-подписью.
#
# Использует фиксированный набор подписей из репозитория, поэтому сколько бы раз
# ни перегенерировался проект — подпись всегда встаёт на свои места:
#   - конфигурация:  build-system/configuration.json (team_id U95EM6ZJRW, dev-сертификат)
#   - профиль/серты: build-system/codesigning-dev  (profiles/Telegram.mobileprovision + certs/)
#
# Подпись ручная (manual), привязана к команде U95EM6ZJRW и конкретному
# development-профилю «Telegram». Приватные ключи сертификатов уже в keychain.
#
# Переменные окружения (опционально):
#   CONFIGURATION_PATH      — путь к configuration.json (по умолчанию: build-system/configuration.json)
#   CODESIGNING_PATH        — каталог с профилями/сертами (по умолчанию: build-system/codesigning-dev)
#   CACHE_DIR               — каталог кэша Bazel (например $HOME/telegram-bazel-cache)
#   OVERRIDE_XCODE_VERSION  — использовать установленную версию Xcode, если она не совпадает с проектной (1/true/yes)
#
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION_PATH="${CONFIGURATION_PATH:-build-system/configuration.json}"
CODESIGNING_PATH="${CODESIGNING_PATH:-build-system/codesigning-dev}"

if [ ! -f "$CONFIGURATION_PATH" ]; then
  echo "Ошибка: конфигурация не найдена: $CONFIGURATION_PATH"
  exit 1
fi
if [ ! -d "$CODESIGNING_PATH/profiles" ]; then
  echo "Ошибка: каталог подписей не найден: $CODESIGNING_PATH/profiles"
  exit 1
fi

echo "Конфигурация: $CONFIGURATION_PATH"
echo "Подпись:      $CODESIGNING_PATH"
echo ""

# Глобальные опции Make идут ДО подкоманды generateProject
GLOBAL_ARGS=()
if [ -n "$CACHE_DIR" ]; then
  GLOBAL_ARGS+=(--cacheDir="$CACHE_DIR")
fi
if [ -n "$OVERRIDE_XCODE_VERSION" ]; then
  case "$OVERRIDE_XCODE_VERSION" in
    1|true|yes|YES) GLOBAL_ARGS+=(--overrideXcodeVersion) ;;
  esac
fi

SUBCOMMAND_ARGS=(
  generateProject
  --configurationPath="$CONFIGURATION_PATH"
  --codesigningInformationPath="$CODESIGNING_PATH"
  --disableExtensions
)

python3 -u build-system/Make/Make.py "${GLOBAL_ARGS[@]}" "${SUBCOMMAND_ARGS[@]}"
