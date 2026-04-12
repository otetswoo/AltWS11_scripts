#!/usr/bin/env bash
# --- Настройки ---
TITLE="Конвертер изображений в WEBP"
MAX_JOBS=$(nproc)
# Оптимальный баланс: визуально без потерь, файлы в 2-5 раз легче
CWEBP_FLAGS="-q 85"

# --- Проверка зависимостей ---
check_deps() {
    local missing=()
    command -v cwebp &>/dev/null || missing+=("libwebp-tools")
    command -v zenity &>/dev/null || missing+=("zenity")
    if [[ ${#missing[@]} -gt 0 ]]; then
        if zenity --question --title="Отсутствуют пакеты" \
            --text="Для работы требуются:\n${missing[*]}\n\nУстановить через apt-get?" \
            --ok-label="Установить" --cancel-label="Отмена"; then
            pkexec apt-get install -y "${missing[@]}" || {
                zenity --error --text="Не удалось установить пакеты."; exit 1; }
            for cmd in cwebp zenity; do
                command -v "$cmd" &>/dev/null || { zenity --error --text="$cmd не установлен."; exit 1; }
            done
        else
            exit 1
        fi
    fi
}
check_deps

# --- Выбор файлов или папки ---
INPUT=$(zenity --file-selection \
    --title="$TITLE - Выберите файл или папку" \
    --multiple --separator=$'\n' --directory) || exit 1

# --- Удаление исходников ---
DELETE_ORIGINAL=$(zenity --list \
    --title="Исходные файлы" \
    --column="Выбор" "Сохранить" "Удалить после конвертации" --height=150) || exit 1

# --- Область обработки ---
SCOPE=$(zenity --list \
    --title="Что обрабатывать?" \
    --column="Режим" --column="Описание" \
    "skip_webp" "Все изображения, КРОМЕ существующих .webp" \
    "include_webp" "ВСЕ изображения + ПЕРЕСЖАТЬ .webp (исправить раздутый размер)" \
    --height=180) || exit 1

# --- Сбор списка файлов ---
FILES=()
EXT_ARGS=(-iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tiff" -o -iname "*.bmp" -o -iname "*.gif")
[[ "$SCOPE" == "include_webp" ]] && EXT_ARGS+=(-o -iname "*.webp")

while IFS= read -r ITEM; do
    [[ -z "$ITEM" ]] && continue
    if [[ -d "$ITEM" ]]; then
        while IFS= read -r -d '' f; do
            FILES+=("$f")
        done < <(find "$ITEM" -type f \( "${EXT_ARGS[@]}" \) -print0)
    elif [[ -f "$ITEM" ]]; then
        FILES+=("$ITEM")
    fi
done <<< "$INPUT"

TOTAL=${#FILES[@]}
[[ $TOTAL -eq 0 ]] && { zenity --error --text="Изображения не найдены."; exit 1; }

# --- Временные файлы для атомарного прогресса ---
COUNTER_FILE=$(mktemp /tmp/webp_cnt.XXXXXX)
LOCK_FILE=$(mktemp /tmp/webp_lock.XXXXXX)
echo 0 > "$COUNTER_FILE"

# --- Обработка одного файла ---
process_file() {
    local FILE="$1" DEL="$2" TOTAL="$3" CNT_FILE="$4" LCK_FILE="$5"
    local BASENAME EXT DIRNAME OUTPUT TMP_OUT
    BASENAME=$(basename "$FILE")
    DIRNAME=$(dirname "$FILE")
    EXT="${BASENAME##*.}"

    # Если входной файл уже .webp и мы его пересжимаем
    if [[ "${EXT,,}" == "webp" ]]; then
        TMP_OUT="${FILE}.tmp"
        # cwebp не умеет писать в тот же файл напрямую, используем временный
        if cwebp $CWEBP_FLAGS "$FILE" -o "$TMP_OUT" &>/dev/null; then
            mv -f "$TMP_OUT" "$FILE"
        else
            rm -f "$TMP_OUT" # Очистка при ошибке
        fi
    else
        # Стандартная конвертация
        OUTPUT="$DIRNAME/${BASENAME%.*}.webp"
        [[ -f "$OUTPUT" ]] && return 0 # Пропуск, если .webp уже есть

        if cwebp $CWEBP_FLAGS "$FILE" -o "$OUTPUT" &>/dev/null; then
            [[ "$DEL" == "Удалить после конвертации" ]] && rm -f "$FILE"
        fi
    fi

    # Атомарное обновление прогресса (потокобезопасно)
    (
        flock -x 200
        local count=$(<"$CNT_FILE")
        echo $((count + 1)) > "$CNT_FILE"
        echo $(( (count + 1) * 100 / TOTAL )) >&3
    ) 200>"$LCK_FILE"
}

# --- Параллельный запуск ---
(
    ACTIVE=0
    for FILE in "${FILES[@]}"; do
        process_file "$FILE" "$DELETE_ORIGINAL" "$TOTAL" "$COUNTER_FILE" "$LOCK_FILE" &
        ((ACTIVE++))
        if (( ACTIVE >= MAX_JOBS )); then
            wait -n
            ((ACTIVE--))
        fi
    done
    wait
) 3>&1 | zenity --progress \
    --title="$TITLE" \
    --percentage=0 \
    --auto-close \
    --text="Обработка изображений..."

RET=${PIPESTATUS[0]}
rm -f "$COUNTER_FILE" "$LOCK_FILE"

[[ $RET -eq 0 ]] && zenity --info --text="Конвертация завершена!" \
                 || zenity --warning --text="Процесс прерван."
