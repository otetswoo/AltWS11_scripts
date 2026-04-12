#!/bin/bash
# Аудио-нормализация с выбором файла/папки, сохранением структуры и прогресс-баром

set -o pipefail

TITLE="Аудио нормализация (ITU BS.1770)"
LOGDIR="/mnt/files/Yandex.Disk/Скрипты/logs"
mkdir -p "$LOGDIR"

need() { command -v "$1" >/dev/null 2>&1 || { zenity --error --text="Не найдено: $1"; exit 1; }; }
need zenity
need ffmpeg
need ffprobe
need realpath

# --- Выбор режима источника ---
SRC_MODE=$(zenity --list --radiolist \
  --title="$TITLE — что обрабатывать?" \
  --column="✓" --column="Источник" \
  TRUE "Папка" FALSE "Файлы" --height=220) || exit 0

declare -a FILES

if [[ "$SRC_MODE" == "Папка" ]]; then
  BASE_DIR=$(zenity --file-selection --directory --title="$TITLE — выберите папку") || exit 0
  [[ -d "$BASE_DIR" ]] || { zenity --error --text="Папка не найдена"; exit 1; }
  # Собираем файлы безопасно (NUL-terminated)
  while IFS= read -r -d '' f; do FILES+=("$f"); done < <(
    find "$BASE_DIR" -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' -o -iname '*.ogg' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.opus' -o -iname '*.wma' \) -print0
  )
  [[ ${#FILES[@]} -gt 0 ]] || { zenity --info --text="В папке аудиофайлов не найдено"; exit 0; }
else
  SEL=$(zenity --file-selection --multiple --separator="|" --title="$TITLE — выберите файлы") || exit 0
  IFS='|' read -r -a FILES <<< "$SEL"
fi

# Уберём возможные дубли (ассоц.массив)
declare -A SEEN
UNIQ=()
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  rp=$(realpath "$f")
  [[ -z "${SEEN[$rp]}" ]] && { SEEN[$rp]=1; UNIQ+=("$rp"); }
done
FILES=("${UNIQ[@]}")
[[ ${#FILES[@]} -gt 0 ]] || { zenity --error --text="Нет валидных файлов"; exit 1; }

# --- Куда писать результат / режим удаления ---
MODE=$(zenity --list --radiolist \
  --title="$TITLE — режим" \
  --column="✓" --column="Действие" \
  TRUE "Сохранить копии (оригиналы остаются)" FALSE "Заменить оригиналы (перезапись)" --height=220) || exit 0

# Для режима копий определим корневую папку результатов
if [[ "$MODE" == "Сохранить копии (оригиналы остаются)" ]]; then
  if [[ "$SRC_MODE" == "Папка" ]]; then
    OUT_ROOT="${BASE_DIR%/}_normalized"
  else
    # для отдельного файла — рядом, в подкаталоге normalized
    PDIR=$(dirname "${FILES[0]}")
    OUT_ROOT="${PDIR%/}/normalized"
  fi
  mkdir -p "$OUT_ROOT" || { zenity --error --text="Не могу создать $OUT_ROOT"; exit 1; }
fi

# --- утилиты ---

# Определяем кодек/битрейт и подбираем эквивалентный энкодер/параметры
encode_params() {
  local in="$1"
  local codec="" br=""
  codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
           -of default=nokey=1:noprint_wrappers=1 "$in" 2>/dev/null | head -n1)
  br=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
           -of default=nokey=1:noprint_wrappers=1 "$in" 2>/dev/null | head -n1)

  # по умолчанию
  local enc="-c:a aac -b:a 192k"

  case "$codec" in
    mp3|mp2|mpeg* )
      if [[ -n "$br" && "$br" -gt 0 ]]; then
        enc="-c:a libmp3lame -b:a $((br))"
      else
        enc="-c:a libmp3lame -q:a 2"
      fi
      ;;
    aac|aac_latm|libfdk_aac|mpeg4aac )
      if [[ -n "$br" && "$br" -gt 0 ]]; then
        enc="-c:a aac -b:a $((br))"
      else
        enc="-c:a aac -b:a 192k"
      fi
      ;;
    flac )
      enc="-c:a flac" ;;
    pcm_s16le|pcm_s24le|pcm_s32le|pcm_s16be|pcm_s24be|pcm_s32be )
      enc="-c:a $codec" ;;
    vorbis )
      if [[ -n "$br" && "$br" -gt 0 ]]; then enc="-c:a libvorbis -b:a $((br))"; else enc="-c:a libvorbis -q:a 5"; fi ;;
    opus )
      if [[ -n "$br" && "$br" -gt 0 ]]; then enc="-c:a libopus -b:a $((br))"; else enc="-c:a libopus -b:a 128k"; fi ;;
    alac )
      enc="-c:a alac" ;;
    wma|wmav2 )
      if [[ -n "$br" && "$br" -gt 0 ]]; then enc="-c:a wmav2 -b:a $((br))"; else enc="-c:a wmav2 -b:a 192k"; fi ;;
    * )
      # неизвестный — падём на AAC 192k
      enc="-c:a aac -b:a 192k" ;;
  esac
  echo "$enc"
}

# Нормализация одного файла с комбинированным прогрессом
process_one() {
  local file="$1" idx="$2" total="$3" base_msg="$4"

  # длительность в секундах
  local duration
  duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null)
  duration=${duration%.*}
  [[ -z "$duration" || "$duration" -le 0 ]] && duration=1

  # куда писать
  local dest tmp logfile
  if [[ "$MODE" == "Сохранить копии (оригиналы остаются)" ]]; then
    if [[ "$SRC_MODE" == "Папка" ]]; then
      local rel
      rel=$(realpath --relative-to="$BASE_DIR" "$file")
      dest="$OUT_ROOT/$rel"
    else
      local dir base
      dir="$(dirname "$file")"
      base="$(basename "$file")"
      dest="$OUT_ROOT/$base"
    fi
    mkdir -p "$(dirname "$dest")"
  else
    dest="$file"
  fi

  tmp="$(dirname "$dest")/.tmp_$$.${dest##*.}"
  logfile="$LOGDIR/$(basename "$file").log"

  local enc; enc=$(encode_params "$file")

  # текст в прогрессе
  echo "# [$idx/$total] $base_msg"

  # запускаем ffmpeg с прогрессом
  # shellcheck disable=SC2086
  if ! ffmpeg -hide_banner -y -i "$file" \
        -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
        $enc \
        -progress pipe:1 -nostats "$tmp" \
        2>>"$logfile" | \
      awk -v d="$duration" -v i="$idx" -v t="$total" -v rel="$base_msg" '
        BEGIN{ last=0 }
        /^out_time_ms=/ {
          split($0,a,"="); s=a[2]/1000000;
          filep = (d>0)? (s*100/d) : 0;
          if (filep > 100) filep=100;
          overall = int(((i-1)*100/t) + (filep/t));
          print overall;
          printf("# [%d/%d] %s — %.1f%% файла\n", i, t, rel, filep);
          fflush();
        }'; then
      echo "# Ошибка: см. лог $logfile"
      return 1
  fi

  # финальный шаг по текущему файлу
  mv -f "$tmp" "$dest"

  if [[ "$MODE" == "Заменить оригиналы (перезапись)" ]]; then
    # уже перезаписали (dest == file)
    :
  fi

  return 0
}

TOTAL=${#FILES[@]}
IDX=0

(
for f in "${FILES[@]}"; do
  IDX=$((IDX+1))
  base_rel="$f"
  if [[ "$SRC_MODE" == "Папка" ]]; then
    base_rel=$(realpath --relative-to="$BASE_DIR" "$f")
  fi
  # обновим текст
  echo "# [$IDX/$TOTAL] Подготовка: $base_rel"
  # обработка
  if process_one "$f" "$IDX" "$TOTAL" "$base_rel"; then
    :
  else
    :
  fi
  # страхующий шаг для процентов (если вдруг ffmpeg не дал прогресс)
  percent=$(( IDX * 100 / TOTAL ))
  echo "$percent"
done
) | zenity --progress --title="$TITLE" --percentage=0 --auto-close --width=700

rc=$?
if [[ $rc -eq 0 ]]; then
  if [[ "$MODE" == "Сохранить копии (оригиналы остаются)" ]]; then
    zenity --info --text="Готово!\nРезультаты: $OUT_ROOT\nЛоги: $LOGDIR"
  else
    zenity --info --text="Готово!\nФайлы перезаписаны.\nЛоги: $LOGDIR"
  fi
else
  zenity --error --text="Процесс прерван.\nПроверьте логи: $LOGDIR"
fi

