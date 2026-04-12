#!/bin/bash
set -uo pipefail

# 1. Проверка зависимостей
MISSING_DEPS=()
for cmd in ffmpeg zenity nice ionice; do
    command -v "$cmd" &>/dev/null || MISSING_DEPS+=("$cmd")
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    if zenity --question --title="Установка ПО" \
        --text="Для работы требуются: ${MISSING_DEPS[*]}.\nУстановить через apt-get?"; then
        sudo apt-get update -qq
        sudo apt-get install -y "${MISSING_DEPS[@]}"
    else
        zenity --error --text="Отмена: отсутствуют необходимые пакеты."
        exit 1
    fi
fi

# 2. Единый диалог настроек
SETTINGS=$(zenity --forms \
    --title="🎬 Сжатие видео" \
    --text="Настройки обработки" \
    --add-entry="Исходная папка (оставьте пустым для выбора)" \
    --add-entry="Выходная папка (пусто = заменить на месте)" \
    --add-entry="CRF качество (18=без потерь / 23=баланс / 28=макс.сжатие)" \
    --separator="|") || exit 1

INPUT_DIR=$(echo "$SETTINGS" | cut -d'|' -f1)
OUTPUT_DIR=$(echo "$SETTINGS" | cut -d'|' -f2)
CRF=$(echo "$SETTINGS"      | cut -d'|' -f3)

# Если поля пустые — открываем файловый диалог
if [ -z "$INPUT_DIR" ]; then
    INPUT_DIR=$(zenity --file-selection --directory --title="📁 Исходная папка с .mp4") || exit 1
fi
INPUT_DIR="${INPUT_DIR%/}"

if [ -z "$OUTPUT_DIR" ]; then
    INPLACE=1
    OUTPUT_DIR="$INPUT_DIR"
else
    INPLACE=0
    OUTPUT_DIR="${OUTPUT_DIR%/}"
    mkdir -p "$OUTPUT_DIR"
fi

# CRF по умолчанию
[[ "$CRF" =~ ^[0-9]+$ ]] || CRF=23

# 3. Поиск файлов
mapfile -d '' FILES < <(find "$INPUT_DIR" -type f -iname "*.mp4" -print0)
TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    zenity --info --text="В папке и вложенных каталогах не найдено файлов .mp4"
    exit 0
fi

# 4. Проверка свободного места в /tmp
LARGEST_FILE=0
for f in "${FILES[@]}"; do
    SIZE=$(stat -c %s "$f")
    [ "$SIZE" -gt "$LARGEST_FILE" ] && LARGEST_FILE="$SIZE"
done
FREE_TMP=$(df --output=avail -B1 /tmp | tail -1)

if [ "$LARGEST_FILE" -gt "$FREE_TMP" ]; then
    LARGEST_MB=$(( LARGEST_FILE / 1024 / 1024 ))
    FREE_MB=$(( FREE_TMP / 1024 / 1024 ))
    zenity --error --title="Недостаточно места" \
        --text="В /tmp недостаточно места.\nНужно: ~${LARGEST_MB} МБ\nДоступно: ${FREE_MB} МБ\n\nОсвободите место или измените /tmp."
    exit 1
fi

# 5. Расчёт нагрузки
TOTAL_CORES=$(nproc)
MAX_JOBS=$(( TOTAL_CORES >= 8 ? 3 : (TOTAL_CORES >= 4 ? 2 : 1) ))
THREADS_PER_JOB=$(( (TOTAL_CORES + MAX_JOBS - 1) / MAX_JOBS ))
[ "$THREADS_PER_JOB" -lt 1 ] && THREADS_PER_JOB=1
[ "$THREADS_PER_JOB" -gt 8 ] && THREADS_PER_JOB=8

# 6. Подготовка
COUNTER_FILE=$(mktemp /tmp/vid_progress.XXXXXX)
BYTES_FILE=$(mktemp /tmp/vid_bytes.XXXXXX)
LOCK_FILE="${COUNTER_FILE}.lock"
TEMP_BASE=$(mktemp -d /tmp/vid_compress_XXXXXX)
echo 0 > "$COUNTER_FILE"
echo 0 > "$BYTES_FILE"

# Суммарный размер для прогресса по байтам
TOTAL_BYTES=0
for f in "${FILES[@]}"; do
    TOTAL_BYTES=$(( TOTAL_BYTES + $(stat -c %s "$f") ))
done

# 7. Обработчик прерывания
cleanup() {
    kill "$ZENITY_PID" 2>/dev/null || true
    wait 2>/dev/null
    rm -rf "$TEMP_BASE" "$COUNTER_FILE" "$BYTES_FILE" "$LOCK_FILE" 2>/dev/null
    echo -e "\n⛔ Прервано. Временные файлы удалены."
    exit 130
}
trap cleanup INT TERM

# 8. Прогресс-бар (по байтам + счётчик файлов)
(
    while true; do
        CUR_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
        CUR_BYTES=$(cat "$BYTES_FILE"   2>/dev/null || echo 0)

        if [ "$CUR_COUNT" -ge "$TOTAL" ]; then
            echo "100"
            echo "# ✅ Готово! Обработано файлов: $TOTAL"
            sleep 1
            break
        fi

        if [ "$TOTAL_BYTES" -gt 0 ]; then
            PCT=$(( CUR_BYTES * 100 / TOTAL_BYTES ))
            [ "$PCT" -gt 99 ] && PCT=99
        else
            PCT=0
        fi

        CUR_MB=$(( CUR_BYTES   / 1024 / 1024 ))
        TOT_MB=$(( TOTAL_BYTES / 1024 / 1024 ))
        echo "$PCT"
        echo "# Файлов: $CUR_COUNT / $TOTAL  |  ${CUR_MB} МБ / ${TOT_MB} МБ  |  Потоков: $MAX_JOBS×$THREADS_PER_JOB  CRF: $CRF"
        sleep 0.5
    done | zenity --progress \
        --title="🎬 Сжатие видео" \
        --text="Запуск..." \
        --percentage=0 \
        --auto-close
) &
ZENITY_PID=$!

# 9. Функция обработки одного файла (экспортируется для xargs)
process_file() {
    local f="$1"
    local INPUT_DIR="$2"
    local OUTPUT_DIR="$3"
    local INPLACE="$4"
    local TEMP_BASE="$5"
    local THREADS_PER_JOB="$6"
    local CRF="$7"
    local COUNTER_FILE="$8"
    local BYTES_FILE="$9"
    local LOCK_FILE="${10}"

    REL_PATH="${f#"$INPUT_DIR"/}"
    TEMP_FILE="$TEMP_BASE/$REL_PATH"
    mkdir -p "$(dirname "$TEMP_FILE")"

    if nice -n 10 ionice -c 2 -n 7 \
       ffmpeg -threads "$THREADS_PER_JOB" -i "$f" \
              -c:v libx264 -crf "$CRF" -preset medium \
              -c:a aac -b:a 128k -movflags +faststart \
              -y "$TEMP_FILE" 2>/dev/null; then

        ORIG_SIZE=$(stat -c %s "$f")
        TEMP_SIZE=$(stat -c %s "$TEMP_FILE")

        if [ "$INPLACE" -eq 1 ]; then
            if [ "$TEMP_SIZE" -lt "$ORIG_SIZE" ]; then
                mv "$TEMP_FILE" "$f"
            else
                rm -f "$TEMP_FILE"
            fi
        else
            FINAL_FILE="$OUTPUT_DIR/$REL_PATH"
            mkdir -p "$(dirname "$FINAL_FILE")"
            if [ "$TEMP_SIZE" -lt "$ORIG_SIZE" ]; then
                mv "$TEMP_FILE" "$FINAL_FILE"
            else
                cp -p "$f" "$FINAL_FILE"
                rm -f "$TEMP_FILE"
            fi
        fi
    else
        rm -f "$TEMP_FILE"
        if [ "$INPLACE" -eq 0 ]; then
            FINAL_FILE="$OUTPUT_DIR/$REL_PATH"
            mkdir -p "$(dirname "$FINAL_FILE")"
            cp -p "$f" "$FINAL_FILE"
        fi
    fi

    FILE_SIZE=$(stat -c %s "$f")
    (
        flock -x 200
        echo $(( $(cat "$COUNTER_FILE") + 1 )) > "$COUNTER_FILE"
        echo $(( $(cat "$BYTES_FILE") + FILE_SIZE ))  > "$BYTES_FILE"
    ) 200>"$LOCK_FILE"
}

export -f process_file

# 10. Запуск через xargs
printf '%s\0' "${FILES[@]}" | xargs -0 -P "$MAX_JOBS" -I{} \
    bash -c 'process_file "$@"' _ {} \
        "$INPUT_DIR" "$OUTPUT_DIR" "$INPLACE" "$TEMP_BASE" \
        "$THREADS_PER_JOB" "$CRF" "$COUNTER_FILE" "$BYTES_FILE" "$LOCK_FILE"

# 11. Завершение
wait "$ZENITY_PID" 2>/dev/null || true
trap - INT TERM
rm -rf "$TEMP_BASE" "$COUNTER_FILE" "$BYTES_FILE" "$LOCK_FILE" 2>/dev/null

if [ "$INPLACE" -eq 1 ]; then
    RESULT_TEXT="Файлы обработаны на месте в:\n$INPUT_DIR"
else
    RESULT_TEXT="Результаты сохранены в:\n$OUTPUT_DIR\n✅ Структура папок сохранена."
fi

zenity --info --title="🎉 Завершено" \
    --text="Обработано файлов: $TOTAL\nCRF: $CRF\n\n$RESULT_TEXT\n\n📦 Файлы, которые не сжались — скопированы/оставлены без изменений."
