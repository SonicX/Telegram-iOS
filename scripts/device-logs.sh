#!/bin/bash
#
# Живые логи Swiftgram с подключённого по кабелю iPhone (без Xcode).
#
# Показывает системный журнал процесса приложения. VO-диагностика
# (voDiagLog / voAccessibilityLog) пишется туда же через os_log, поэтому видна
# здесь без отладчика. Всё выведенное параллельно сохраняется в файл
# build/device-logs/<дата-время>.log — его можно приложить к задаче.
#
# Использование:
#   scripts/device-logs.sh          — только VO-логи ([VO-…])
#   scripts/device-logs.sh --all    — все логи процесса приложения
#   scripts/device-logs.sh --grep ТЕКСТ — только строки с ТЕКСТ
#
# Остановить: Ctrl+C.
#
# Подробные [VO-…] логи фокуса (voAccessibilityLog) по умолчанию выключены
# флагом voVerboseAccessibilityLogging — здесь видны только [VO-DIAG] и прочие
# всегда включённые.
#
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS="${PROCESS:-Swiftgram}"

FILTER="VO"
while [ $# -gt 0 ]; do
  case "$1" in
    --all) FILTER="" ;;
    --grep) shift; FILTER="$1" ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
  shift
done

UDID_ARGS=()
if [ -n "$DEVICE_UDID" ]; then
  UDID_ARGS=(-u "$DEVICE_UDID")
fi

LOG_DIR="$REPO_ROOT/build/device-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"

echo "Логи процесса $PROCESS${FILTER:+, фильтр: $FILTER}. Файл: $LOG_FILE"
echo "Ctrl+C — остановить."
echo ""

if [ -n "$FILTER" ]; then
  idevicesyslog "${UDID_ARGS[@]}" -p "$PROCESS" --no-colors | grep --line-buffered -F -- "$FILTER" | tee "$LOG_FILE"
else
  idevicesyslog "${UDID_ARGS[@]}" -p "$PROCESS" --no-colors | tee "$LOG_FILE"
fi
