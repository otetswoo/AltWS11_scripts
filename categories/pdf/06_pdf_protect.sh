#!/usr/bin/env bash
# PDF → изображения → PDF ("скан-эффект" для защиты от копирования)
# Выбор DPI: 100 / 150 / 200 / 300
# Многопоточность: MAGICK_THREAD_LIMIT + convert -limit thread
# Проверка места: динамическая оценка с учётом DPI
# Режим: бесконечный цикл с запросом на продолжение после каждого запуска
set -uo pipefail
IFS=$'\n\t'

TITLE="PDF → Скан (Защита от копирования)"
LOG_DIR="/mnt/files/Yandex.Disk/Скрипты/logs"
LOG_FILE="$LOG_DIR/pdf_scan_convert.log"
mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Ядра CPU для многопоточности
NPROC=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 2)
export MAGICK_THREAD_LIMIT="$NPROC"
export OMP_NUM_THREADS="$NPROC"

# Определяем команду ImageMagick (v7: magick, v6: convert)
IM_CMD=$(command -v magick 2>/dev/null || command -v convert 2>/dev/null || echo "convert")

# ==========================================================
# Проверка зависимостей с GUI-установкой (выполняется 1 раз)
# ==========================================================
check_deps() {
    local missing=()
    local cmds=("pdftoppm" "$IM_CMD" "zenity")
    local pkgs=("poppler-utils" "imagemagick" "zenity")

    for i in "${!cmds[@]}"; do
        command -v "${cmds[$i]}" &>/dev/null || missing+=("${pkgs[$i]}")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    local pkg_str="${missing[*]}"
    zenity --question --no-wrap --width=500 \
        --text="Отсутствуют необходимые пакеты:\n<b>$pkg_str</b>\n\nУстановить сейчас? (потребуется пароль)" || exit 1

    local priv_cmd=""
    if command -v pkexec &>/dev/null; then priv_cmd="pkexec"
    elif command -v sudo &>/dev/null; then priv_cmd="sudo"
    else
        zenity --error --text="Нет средств повышения прав (pkexec/sudo).\nУстановите вручную: $pkg_str"
        exit 1
    fi

    zenity --info --no-wrap --width=400 --text="Запуск установки через $priv_cmd...\nДождитесь завершения в терминале."
    if command -v apt-get &>/dev/null; then
        $priv_cmd apt-get install -y "${missing[@]}"
    elif command -v epm &>/dev/null; then
        $priv_cmd epm install -y "${missing[@]}"
    else
        zenity --error --text="Менеджер пакетов (apt-get/epm) не найден."
        exit 1
    fi
    zenity --info --text="Пакеты установлены.\nПерезапустите скрипт."
    exit 0
}

# ==========================================================
# Проверка свободного места
# ==========================================================
check_free_space_mb() {
    local path="$1" required_mb="$2"
    local avail_kb
    avail_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2{print $4}') || return 1
    local avail_mb=$((avail_kb / 1024))
    [[ $avail_mb -ge $required_mb ]]
}

estimate_space_mb() {
    local file="$1" dpi="$2"
    local size_bytes size_mb
    size_bytes=$(stat -c%s "$file" 2>/dev/null) || size_bytes=$(wc -c < "$file" 2>/dev/null) || size_bytes=0
    size_mb=$((size_bytes / 1048576))
    
    # Коэффициент роста временных файлов зависит от DPI²
    local factor
    case $dpi in
        100) factor=2  ;;
        150) factor=3  ;;
        200) factor=5  ;;
        300) factor=12 ;;
        *)   factor=3  ;;
    esac
    
    local needed=$(( size_mb * factor + 300 )) # +300 МБ системный запас
    [[ $needed -lt 400 ]] && needed=400
    echo "$needed"
}

# ==========================================================
# Генерация уникального имени выходного файла
# ==========================================================
out_name_for() {
    local in="$1" dir base candidate n=1
    dir="$(dirname "$in")"
    base="$(basename "$in")"
    base="${base%.*}"
    candidate="${dir}/${base}_scanned.pdf"
    while [[ -e "$candidate" ]]; do
        candidate="${dir}/${base}_scanned_${n}.pdf"
        ((n++))
    done
    printf '%s' "$candidate"
}

# ==========================================================
# Конвертация одного файла
# ==========================================================
compress_one() {
    local in="$1" dpi="$2"
    [[ -f "$in" ]] || { log "SKIP: не файл: $in"; return 1; }
    [[ "${in,,}" == *.pdf ]] || { log "SKIP: не PDF: $in"; return 1; }

    local out target_dir
    out="$(out_name_for "$in")"
    target_dir="$(dirname "$out")"

    # 🔍 Проверка места на целевом диске и в TMPDIR
    local req_mb
    req_mb=$(estimate_space_mb "$in" "$dpi")
    if ! check_free_space_mb "$target_dir" "$req_mb"; then
        log "SKIP: Недостаточно места в $target_dir (требуется ~${req_mb} МБ)"
        return 1
    fi
    local tmp_base="${TMPDIR:-/tmp}"
    if ! check_free_space_mb "$tmp_base" "$req_mb"; then
        log "SKIP: Недостаточно места в $tmp_base для временных файлов (требуется ~${req_mb} МБ)"
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d -p "$tmp_base")" || { log "ERR: mktemp failed"; return 1; }
    trap 'rm -rf "$tmpdir" 2>/dev/null' RETURN

    log "START (DPI=$dpi): $in -> $out"
    rm -f "$tmpdir"/page-*.png "$tmpdir"/page-*.jpg "$tmpdir"/list.txt 2>/dev/null || true

    # 1. PDF → PNG с выбранным DPI
    if ! pdftoppm -png -r "$dpi" "$in" "$tmpdir/page" >/dev/null 2>&1; then
        log "ERROR: pdftoppm failed (возможно, защищён паролем или повреждён): $in"
        return 1
    fi

    shopt -s nullglob
    local pngs=("$tmpdir"/page-*.png)
    shopt -u nullglob
    [[ ${#pngs[@]} -eq 0 ]] && { log "ERROR: no pages generated for $in"; return 1; }

    # 2. PNG → JPG (пакетно, многопоточно)
    if ! $IM_CMD mogrify -format jpg -quality 75 "${pngs[@]}" >/dev/null 2>&1; then
        log "ERROR: mogrify failed for $in"
        return 1
    fi
    rm -f "${pngs[@]}" 2>/dev/null

    # 3. JPG → PDF (безопасная сборка через @filelist обходит ARG_MAX)
    local jpgs=("$tmpdir"/page-*.jpg)
    printf '%s\n' "${jpgs[@]}" > "$tmpdir/list.txt"

    if ! $IM_CMD convert -limit thread "$NPROC" -compress jpeg "@$tmpdir/list.txt" "$out" >/dev/null 2>&1; then
        log "ERROR: convert JPG->PDF failed for $in"
        return 1
    fi

    local size_after
    size_after=$(du -h "$out" 2>/dev/null | awk '{print $1}')
    log "OK: $out (size: $size_after)"
    return 0
}

# ==========================================================
# Основной блок (в бесконечном цикле)
# ==========================================================
check_deps

while true; do
    # 🎛 Выбор DPI
    DPI=$(zenity --list --radiolist --title="Выберите разрешение (DPI)" \
        --column="Выбор" --column="DPI" --column="Качество / Размер" \
        FALSE 100 "Низкое / Быстро, малый размер" \
        TRUE 150 "Среднее / Рекомендуемый баланс" \
        FALSE 200 "Высокое / ~2x размер и время" \
        FALSE 300 "Макс. / ~4x размер, печать" 2>/dev/null) || break
    DPI=${DPI:-150}

    # 📁 Выбор режима
    MODE=$(zenity --list --radiolist --title="$TITLE" \
        --column "" --column "Выбрать" TRUE "Файл" FALSE "Папка" 2>/dev/null) || break

    FILES=()
    if [[ "$MODE" == "Файл" ]]; then
        FILE=$(zenity --file-selection --title="$TITLE — выберите PDF" --file-filter="*.pdf" 2>/dev/null) || break
        [[ -n "$FILE" ]] && FILES+=("$FILE")
    else
        DIR=$(zenity --file-selection --directory --title="$TITLE — выберите папку" 2>/dev/null) || break
        if [[ -n "$DIR" ]]; then
            while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$DIR" -type f -iname '*.pdf' -print0 | sort -z)
        fi
    fi

    if [[ ${#FILES[@]} -eq 0 ]]; then
        zenity --info --text="PDF-файлы не найдены."
        continue # Возврат в начало цикла
    fi

    TOTAL=${#FILES[@]}
    DONE=0
    FAILED=0
    RESULT_FILE=$(mktemp)
    echo "0 0" > "$RESULT_FILE"

    # Потоковый вывод для zenity progress
    (
        done_count=0
        fail_count=0
        processed=0
        for f in "${FILES[@]}"; do
            echo "# Обработка: $(basename "$f")"
            if compress_one "$f" "$DPI"; then
                done_count=$((done_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            processed=$((processed + 1))
            echo $(( processed * 100 / TOTAL ))
        done
        echo "$done_count $fail_count" > "$RESULT_FILE"
    ) | zenity --progress --title="$TITLE (DPI: $DPI)" --percentage=0 --auto-close --width=600 --text="Подготовка..."

    PIPE_SUB=${PIPESTATUS[0]}
    PIPE_ZEN=${PIPESTATUS[1]}
    read -r DONE FAILED < "$RESULT_FILE" 2>/dev/null || { DONE=0; FAILED=0; }
    rm -f "$RESULT_FILE"

    if [[ $PIPE_ZEN -eq 0 ]]; then
        zenity --info --no-wrap --width=400 \
            --text="✅ Готово!\n\nУспешно: $DONE\nПропущено/Ошибки: $FAILED\n\nЛог: $LOG_FILE"
    else
        zenity --warning --no-wrap --width=400 \
            --text="⚠️ Процесс прерван пользователем или завершён с ошибками.\nПроверьте лог: $LOG_FILE\n\nУспешно: $DONE\nПропущено/Ошибки: $FAILED"
    fi

    # 🔄 Запрос на продолжение работы
    if ! zenity --question --title="Продолжить?" --no-wrap --width=350 \
        --text="Обработать ещё файлы или папки?" 2>/dev/null; then
        break # Выход из цикла при выборе "Нет" или закрытии окна
    fi
done

zenity --info --title="Завершение" --text="Работа скрипта завершена.\nСпасибо за использование!"
exit 0
