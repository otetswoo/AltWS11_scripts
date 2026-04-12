#!/usr/bin/env bash
# PDF Compress: Многопоточный, Zenity GUI, защита от увеличения размера
# Добавлено: сравнение размеров, сохранение меньшего файла
# Совместим с Alt Рабочая станция 11 (Bash 5.1, GNOME)
set -uo pipefail

# ═══════════════════════════════════════════════════════════
# 📦 НАСТРОЙКИ
# ═══════════════════════════════════════════════════════════
MAX_JOBS=2 # gs тяжелый, 2 потока оптимальны для CPU/I/O баланса
TMP_DIR=$(mktemp -d /tmp/pdf_compress.XXXXXX)
COUNTER_FILE="$TMP_DIR/counter"
LOCK_FILE="$COUNTER_FILE.lock"
LOG_FILE="$TMP_DIR/process.log"
echo "0" > "$COUNTER_FILE"
touch "$LOG_FILE"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null
  kill "$ZPID" 2>/dev/null
  wait "$ZPID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ═══════════════════════════════════════════════════════════
# 🔍 ЗАВИСИМОСТИ
# ═══════════════════════════════════════════════════════════
check_deps() {
  local missing=()
  command -v gs >/dev/null 2>&1 || missing+=("ghostscript")
  command -v zenity >/dev/null 2>&1 || missing+=("zenity")
  command -v flock >/dev/null 2>&1 || missing+=("util-linux")
  command -v stat >/dev/null 2>&1 || missing+=("coreutils")

  if [[ ${#missing[@]} -gt 0 ]]; then
    local msg="Требуются пакеты: ${missing[*]}\nУстановить сейчас?"
    if command -v zenity >/dev/null 2>&1; then
      zenity --question --text="$msg" --ok-label="Установить" --cancel-label="Отмена" 2>/dev/null || exit 0
    else
      echo "$msg"; read -rp "Установить? (y/n): " ans
      [[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0
    fi
    echo "📦 Установка..."
    sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}" >/dev/null 2>&1
  fi
}

# ═══════════════════════════════════════════════════════════
# 🎛️ ВЫБОР ФАЙЛОВ И РЕЖИМА
# ═══════════════════════════════════════════════════════════
select_mode() {
  zenity --list --radiolist --title="Режим сохранения" --text="Что делать с исходными PDF?" \
    --column="" --column="Действие" \
    TRUE "Оставить (создать копии с _compressed)" \
    FALSE "Заменить исходные файлы" \
    --width=450 --height=200 2>/dev/null || exit 0
}

select_paths() {
  local mode
  mode=$(zenity --list --radiolist --title="Источники" --text="Откуда брать файлы?" \
    --column="" --column="Тип" \
    TRUE "Один или несколько файлов" \
    FALSE "Папка (рекурсивно)" \
    --width=350 --height=200 2>/dev/null) || exit 0

  local paths=()
  if [[ "$mode" == "Один или несколько файлов" ]]; then
    local sel
    sel=$(zenity --file-selection --multiple --file-filter="PDF|*.pdf" --title="Выберите PDF" 2>/dev/null) || exit 0
    IFS='|' read -ra paths <<< "$sel"
  else
    local dir
    dir=$(zenity --file-selection --directory --title="Выберите папку" 2>/dev/null) || exit 0
    [[ -z "$dir" ]] && exit 0
    mapfile -t paths < <(find "$dir" -type f -iname '*.pdf' 2>/dev/null | sort)
  fi

  if [[ ${#paths[@]} -eq 0 ]]; then
    zenity --info --text="Файлы не выбраны или папка пуста." --title="Информация" 2>/dev/null
    exit 0
  fi
  printf '%s\n' "${paths[@]}"
}

# ═══════════════════════════════════════════════════════════
# 📊 ПРОГРЕСС-БАР (ИЗОЛИРОВАННЫЙ ПУЛЛИНГ)
# ═══════════════════════════════════════════════════════════
start_progress() {
  local total=$1
  (
    while true; do
      local cur
      cur=$(cat "$COUNTER_FILE" 2>/dev/null) || cur=0
      [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
      
      local pct=0
      [[ $total -gt 0 ]] && pct=$(( cur * 100 / total ))
      
      echo "$pct"
      echo "# 🔄 Готово: $cur из $total"
      [[ $cur -ge $total ]] && break
      sleep 0.2
    done | zenity --progress --title="Оптимизация PDF" --percentage=0 --auto-close --no-cancel --width=450 2>/dev/null
  ) &
  ZPID=$!
}

# ═══════════════════════════════════════════════════════════
# 📉 ОБРАБОТКА ОДНОГО ФАЙЛА (ФУНКЦИЯ В ФОНЕ)
# ═══════════════════════════════════════════════════════════
compress_one() {
  local in="$1" mode="$2"
  local dir base out rc
  dir="$(dirname "$in")"
  base="$(basename "$in" .pdf)"

  if [[ "$mode" == "Оставить (создать копии с _compressed)" ]]; then
    out="${dir}/${base}_compressed.pdf"
    [[ -f "$out" ]] && { update_counter; return 0; }
  else
    out="${in}.tmp_gs.pdf"
  fi

  # Запуск gs с таймаутом
  timeout 120 gs -dNOPAUSE -dBATCH -dSAFER \
     -sDEVICE=pdfwrite -dCompatibilityLevel=1.5 -dPDFSETTINGS=/prepress \
     -dDetectDuplicateImages=true -dCompressFonts=true -dSubsetFonts=true \
     -dDownsampleColorImages=true -dColorImageResolution=300 -dColorImageFilter=/DCTEncode \
     -dDownsampleGrayImages=true -dGrayImageResolution=300 -dGrayImageFilter=/DCTEncode \
     -dDownsampleMonoImages=true -dMonoImageResolution=1200 -dMonoImageFilter=/CCITTFaxEncode \
     -dJPEGQ=85 -dAutoRotatePages=/None \
     -sOutputFile="$out" "$in" 2>>"$LOG_FILE" >/dev/null
  rc=$?

  if [[ $rc -eq 0 && -f "$out" ]]; then
    # 🆕 Сравнение размеров: оставляем меньший файл
    local orig_size new_size
    orig_size=$(stat -c%s "$in" 2>/dev/null || echo 0)
    new_size=$(stat -c%s "$out" 2>/dev/null || echo 0)

    if [[ $new_size -ge $orig_size ]]; then
      rm -f "$out"
      echo "[$(date +%T)] SKIP: $in (${orig_size} -> ${new_size} байт). Сжатый файл не меньше оригинала." >> "$LOG_FILE"
    else
      if [[ "$mode" == "Заменить исходные файлы" ]]; then
        mv -f "$out" "$in" 2>/dev/null || true
      fi
      # Файл успешно сжат и заменён/сохранён
    fi
  else
    echo "[$(date +%T)] ERROR gs (код $rc): $in" >> "$LOG_FILE"
    [[ -f "$out" ]] && rm -f "$out"
  fi

  update_counter
}

update_counter() {
  (
    flock -x 200
    local val
    val=$(cat "$COUNTER_FILE") || val=0
    [[ "$val" =~ ^[0-9]+$ ]] || val=0
    echo $(( val + 1 )) > "$COUNTER_FILE"
  ) 200>"$LOCK_FILE"
}

# ═══════════════════════════════════════════════════════════
# 🚀 ОСНОВНОЙ ПОТОК
# ═══════════════════════════════════════════════════════════
main() {
  check_deps
  
  local MODE_SAVE
  MODE_SAVE=$(select_mode)
  mapfile -t FILES < <(select_paths)
  local TOTAL=${#FILES[@]}
  [[ $TOTAL -eq 0 ]] && exit 0

  start_progress "$TOTAL"

  local running=0
  for f in "${FILES[@]}"; do
    compress_one "$f" "$MODE_SAVE" &
    running=$(( running + 1 ))
    
    if [[ $running -ge $MAX_JOBS ]]; then
      wait -n 2>/dev/null || wait $(jobs -p) 2>/dev/null
      running=$(( running - 1 ))
    fi
  done
  wait 2>/dev/null

  local DONE=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  [[ ! "$DONE" =~ ^[0-9]+$ ]] && DONE=0

  local msg="✅ Завершено!\nОбработано: $DONE из $TOTAL файлов."
  if grep -q "SKIP:" "$LOG_FILE" 2>/dev/null; then
    msg+="\n📉 Часть файлов не сожата: итоговый размер оказался больше оригинала. Оригинал сохранён."
  fi
  if grep -q "ERROR" "$LOG_FILE" 2>/dev/null; then
    msg+="\n⚠️ Были ошибки обработки. Лог: /tmp/pdf_log_$$.log"
    cp "$LOG_FILE" "/tmp/pdf_log_$$.log" 2>/dev/null
  fi

  zenity --info --text="$msg" --title="Готово" --ok-label="Отлично" 2>/dev/null
}

main "$@"
