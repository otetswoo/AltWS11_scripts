#!/bin/bash
# Отключаем set -e: он вызывает тихие падения при отмене диалогов или фоновых задачах
set -uo pipefail

# ==========================================
# 1. Проверка зависимостей (запуск от пользователя)
# ==========================================
check_dependencies() {
    local missing=()
    for cmd in nmap zenity ip awk; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ ${#missing[@]} -eq 0 ] && return 0

    local pm=""
    command -v epm &>/dev/null && pm="epm"
    command -v apt-get &>/dev/null && pm="apt-get"
    [ -z "$pm" ] && { echo "❌ Менеджер пакетов не найден."; exit 1; }

    if command -v zenity &>/dev/null; then
        zenity --question --title="Установка зависимостей" \
            --text="Необходимы: ${missing[*]}.\nУстановить через $pm?" 2>/dev/null || exit 1
    else
        read -p "Установить ${missing[*]} через $pm? [y/N]: " ans
        [[ "$ans" =~ ^[Yy] ]] || exit 1
    fi

    echo "📦 Установка через $pm..."
    sudo $pm install -y "${missing[@]}" || { echo "❌ Ошибка установки."; exit 1; }
}

# ==========================================
# 2. Проверка прав и кэширование sudo
# ==========================================
check_sudo() {
    echo "🔑 Проверка доступа к сети..."
    sudo -v
    if [ $? -ne 0 ]; then
        zenity --error --text="Не удалось получить права sudo.\nСкрипт не может сканировать без root." 2>/dev/null
        exit 1
    fi
    echo "✅ Права sudo получены."
}

# ==========================================
# 3. Обнаружение и выбор подсетей
# ==========================================
select_subnets() {
    # Безопасный вывод маршрутов без зацикливания и лишних интерфейсов
    local routes
    routes=$(ip -o route show scope link 2>/dev/null | \
             awk '/^[0-9]/ {print $1, $NF}' | \
             grep -vE '/32$|^127\.' | sort -u)

    if [ -z "$routes" ]; then
        zenity --error --text="Активные подсети не найдены.\nПроверьте подключение к сети." 2>/dev/null
        exit 1
    fi

    local zenity_args=(zenity --list --checklist --title="Выбор сегментов" \
        --text="Отметьте подсети для анализа:" \
        --column="Подсеть" --column="Интерфейс" \
        --width=500 --height=350 --separator="|")

    while read -r net iface; do
        zenity_args+=(FALSE "$net" "$iface")
    done <<< "$routes"

    local selected
    selected=$("${zenity_args[@]}" 2>/dev/null) || return 1
    [ -z "$selected" ] && return 1

    # Zenity возвращает: subnet1|iface1|subnet2|iface2...
    # Извлекаем только нечётные поля (подсети)
    echo "$selected" | awk -F'|' '{for(i=1;i<=NF;i+=2) print $i}'
}

# ==========================================
# 4. Сканирование подсети (фоновый процесс)
# ==========================================
scan_subnet() {
    local subnet="$1" out_dir="$2" detailed="$3"
    local mask="${subnet##*/}"
    local total

    case "$mask" in
        32) total=1 ;;
        31) total=2 ;;
        *)  total=$(( (1 << (32 - mask)) - 2 )) ;;
    esac

    # Безопасный подсчёт активных хостов
    local active
    active=$(sudo nmap -sn -T4 --host-timeout 3000 "$subnet" 2>/dev/null | grep -c "Nmap scan report for" || true)
    active=${active:-0}

    local device_stats=""
    if [ "$detailed" = "true" ] && [ "$active" -gt 0 ]; then
        # Извлекаем MAC и вендора. Формат nmap: "MAC Address: 00:11:22:33:44:55 (Vendor)"
        local macs
        macs=$(sudo nmap -sn -T4 --script mac-lookup "$subnet" 2>/dev/null | \
               sed -nE 's/.*MAC Address: ([0-9A-F:]+) \((.+)\)/\1\t\2/p' || true)

        declare -A types=( [mobile]=0 [pc]=0 [printer]=0 [camera]=0 [network]=0 [iot]=0 [unknown]=0 )
        while IFS=$'\t' read -r mac vendor; do
            [ -z "$mac" ] || [ -z "$vendor" ] && continue
            local dtype="unknown"
            case "${vendor,,}" in
                *apple*|*samsung*|*xiaomi*|*huawei*|*oneplus*|*oppo*|*vivo*|*sony*|*lg*|*motorola*|*google*|*realme*) dtype="mobile" ;;
                *dell*|*lenovo*|*acer*|*asus*|*msi*|*microsoft*|*hp*) dtype="pc" ;;
                *canon*|*epson*|*brother*|*kyocera*|*xerox*|*ricoh*|*lexmark*) dtype="printer" ;;
                *hikvision*|*dahua*|*axis*|*bosch*|*vivotek*|*reolink*|*amcrest*) dtype="camera" ;;
                *cisco*|*juniper*|*ubiquiti*|*mikrotik*|*netgear*|*dlink*|*tplink*) dtype="network" ;;
                *tuya*|*sonoff*|*yeelight*|*philips*|*ikea*|*amazon*|*google.*home*) dtype="iot" ;;
            esac
            # Безопасный инкремент без риска для pipefail
            types[$dtype]=$(( ${types[$dtype]:-0} + 1 ))
        done <<< "$macs"
        device_stats="mobile:${types[mobile]}|pc:${types[pc]}|printer:${types[printer]}|camera:${types[camera]}|network:${types[network]}|iot:${types[iot]}|unknown:${types[unknown]}"
    fi

    local percent=0
    [ "$total" -gt 0 ] && percent=$(( active * 100 / total ))
    [ "$percent" -gt 100 ] && percent=100

    # Атомарная запись результата
    echo "${subnet}|${active}|${total}|${percent}|${device_stats}" > "${out_dir}/${subnet//\//_}.res"
}

# ==========================================
# 5. Генерация HTML-отчёта
# ==========================================
generate_html() {
    local out_file="$1" out_dir="$2" has_details="$3"
    local date_now; date_now=$(date '+%d.%m.%Y %H:%M')

    local chart_labels=() chart_values=() chart_colors=()
    if [ "$has_details" = "true" ]; then
        declare -A totals=( [mobile]=0 [pc]=0 [printer]=0 [camera]=0 [network]=0 [iot]=0 [unknown]=0 )
        while IFS='|' read -r _ _ _ _ stats; do
            [ -z "$stats" ] && continue
            IFS='|' read -ra items <<< "$stats"
            for item in "${items[@]}"; do
                IFS=':' read -r dtype count <<< "$item"
                [ -n "${totals[$dtype]+x}" ] && totals[$dtype]=$(( ${totals[$dtype]} + count ))
            done
        done < <(cat "$out_dir"/*.res 2>/dev/null)

        local icons=( mobile:"📱 Мобильные" pc:"🖥️ ПК/Ноутбуки" printer:"🖨️ Принтеры" camera:"📹 Камеры" network:"🔌 Сетевое" iot:"💡 IoT" unknown:"❓ Прочее" )
        local colors=( mobile:"#36A2EB" pc:"#FF6384" printer:"#FFCE56" camera:"#4BC0C0" network:"#9966FF" iot:"#FF9F40" unknown:"#C9CBCF" )

        for dtype in mobile pc printer camera network iot unknown; do
            if [ "${totals[$dtype]}" -gt 0 ]; then
                chart_labels+=("${icons[$dtype]}")
                chart_values+=("${totals[$dtype]}")
                chart_colors+=("${colors[$dtype]}")
            fi
        done
    fi

    cat > "$out_file" << 'HTML_HEAD'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8">
<title>Анализ сетевых устройств</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  body { font-family: system-ui, -apple-system, sans-serif; margin: 40px; background: #f5f7fa; color: #212529; }
  .card { background: #fff; padding: 30px; border-radius: 12px; box-shadow: 0 4px 16px rgba(0,0,0,0.08); }
  h2 { border-bottom: 2px solid #0d6efd; padding-bottom: 10px; }
  table { width: 100%; border-collapse: collapse; margin: 15px 0; }
  th { background: #e9ecef; padding: 10px; text-align: left; }
  td { padding: 10px; border-bottom: 1px solid #dee2e6; }
  .bar { background: #e9ecef; height: 20px; border-radius: 10px; overflow: hidden; }
  .fill { height: 100%; color: #fff; font-weight: bold; display: flex; align-items: center; justify-content: center; font-size: 11px; }
  .low { background: #20c997; } .med { background: #fd7e14; } .high { background: #e03131; }
  .chart-wrap { height: 350px; margin: 20px 0; }
  .footer { text-align: center; font-size: 0.85em; color: #6c757d; margin-top: 20px; border-top: 1px solid #dee2e6; padding-top: 10px; }
</style></head><body><div class="card">
HTML_HEAD

    echo "  <h2>📊 Отчёт по загрузке сети</h2>" >> "$out_file"
    echo "  <p><strong>Дата:</strong> $date_now</p>" >> "$out_file"
    echo '  <table><thead><tr><th>Подсеть</th><th>Устройств</th><th>Всего адресов</th><th>Загрузка</th><th>Статус</th></tr></thead><tbody>' >> "$out_file"

    while IFS='|' read -r net active total percent _; do
        [ -z "$net" ] && continue
        local st="Норма ✅" cls="low"
        [ "$percent" -ge 50 ] && [ "$percent" -lt 80 ] && { st="Умеренно ⚠️"; cls="med"; }
        [ "$percent" -ge 80 ] && { st="Критично 🔴"; cls="high"; }
        echo "    <tr><td><strong>$net</strong></td><td>$active</td><td>$total</td><td><div class=\"bar\"><div class=\"fill $cls\" style=\"width:${percent}%\">${percent}%</div></div></td><td>$st</td></tr>" >> "$out_file"
    done < <(sort "$out_dir"/*.res 2>/dev/null)

    echo '  </tbody></table>' >> "$out_file"

    if [ "$has_details" = "true" ] && [ ${#chart_labels[@]} -gt 0 ]; then
        local labels_json=$(printf '"%s",' "${chart_labels[@]}"); labels_json=${labels_json%,}
        local data_json=$(IFS=,; echo "${chart_values[*]}")
        local colors_json=$(printf '"%s",' "${chart_colors[@]}"); colors_json=${colors_json%,}

        cat >> "$out_file" << CHART
  <h3>📈 Распределение устройств</h3>
  <div class="chart-wrap"><canvas id="devChart"></canvas></div>
  <script>
    new Chart(document.getElementById('devChart'), {
      type: 'doughnut',
      data: {
        labels: [$labels_json],
        datasets: [{  [$data_json], backgroundColor: [$colors_json] }]
      },
      options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: 'right' } } }
    });
  </script>
CHART
    fi

    echo '  <div class="footer">Сформировано автоматически • IT-отдел</div></div></body></html>' >> "$out_file"
}

# ==========================================
# ГЛАВНАЯ ЛОГИКА
# ==========================================
main() {
    check_dependencies
    check_sudo

    echo "🔍 Поиск доступных подсетей..."
    mapfile -t selected_subnets < <(select_subnets)
    if [ ${#selected_subnets[@]} -eq 0 ]; then
        echo "❌ Подсети не выбраны или отмена."
        exit 0
    fi
    echo "✅ Выбрано сегментов: ${#selected_subnets[@]}"

    local detailed="false"
    if zenity --question --title="Режим сканирования" \
        --text="Включить определение типов устройств (мобильные, ПК, камеры)?\n⏱ Время увеличится в 3-5 раз." \
        --no-wrap 2>/dev/null; then
        detailed="true"
        echo "🔍 Режим детального анализа активирован"
    fi

    TMPDIR_WORK=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_WORK"' EXIT INT TERM

    echo "⏳ Сканирование (до 4 потоков)..."
    pids=()
    for subnet in "${selected_subnets[@]}"; do
        scan_subnet "$subnet" "$TMPDIR_WORK" "$detailed" &
        pids+=($!)
        # Безопасное ограничение параллелизма (работает на Bash 3.2+)
        while [ ${#pids[@]} -ge 4 ]; do
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
        done
    done
    wait "${pids[@]}" 2>/dev/null || true

    # Сбор результатов
    results_file="${TMPDIR_WORK}/all_results.csv"
    cat "$TMPDIR_WORK"/*.res > "$results_file" 2>/dev/null || { echo "❌ Нет данных."; exit 1; }

    # ==========================================
    # 🖥️ ВЫВОД В ТЕРМИНАЛ
    # ==========================================
    echo -e "\n$(printf '=%.0s' {1..60})"
    echo "📊 РЕЗУЛЬТАТЫ СКАНИРОВАНИЯ"
    echo "$(printf '=%.0s' {1..60})"
    printf "%-20s | %-8s | %-8s | %-10s | %s\n" "Подсеть" "Хосты" "Всего" "Загрузка" "Статус"
    echo "$(printf -- '-%.0s' {1..60})"
    while IFS='|' read -r net active total percent _; do
        [ -z "$net" ] && continue
        status="✅ Норма"
        [ "$percent" -ge 50 ] && [ "$percent" -lt 80 ] && status="⚠️ Умеренно"
        [ "$percent" -ge 80 ] && status="🔴 Критично"
        printf "%-20s | %-8s | %-8s | %-10s | %s\n" "$net" "$active" "$total" "$percent%" "$status"
    done < <(sort "$results_file")

    if [ "$detailed" = "true" ]; then
        echo -e "\n📦 РАСПРЕДЕЛЕНИЕ УСТРОЙСТВ:"
        declare -A gtypes=( [mobile]=0 [pc]=0 [printer]=0 [camera]=0 [network]=0 [iot]=0 [unknown]=0 )
        while IFS='|' read -r _ _ _ _ stats; do
            [ -z "$stats" ] && continue
            IFS='|' read -ra items <<< "$stats"
            for item in "${items[@]}"; do
                IFS=':' read -r dtype count <<< "$item"
                [ -n "${gtypes[$dtype]+x}" ] && gtypes[$dtype]=$(( ${gtypes[$dtype]} + count ))
            done
        done < "$results_file"
        printf "%-15s : %s\n" "📱 Мобильные" "${gtypes[mobile]}"
        printf "%-15s : %s\n" "🖥️ ПК/Ноутбуки" "${gtypes[pc]}"
        printf "%-15s : %s\n" "🖨️ Принтеры" "${gtypes[printer]}"
        printf "%-15s : %s\n" "📹 Камеры" "${gtypes[camera]}"
        printf "%-15s : %s\n" "🔌 Сетевое" "${gtypes[network]}"
        printf "%-15s : %s\n" "💡 IoT" "${gtypes[iot]}"
        printf "%-15s : %s\n" "❓ Прочее" "${gtypes[unknown]}"
    fi
    echo "$(printf '=%.0s' {1..60})"

    # ==========================================
    # 📄 ГЕНЕРАЦИЯ HTML-ОТЧЁТА
    # ==========================================
    if zenity --question --title="Отчёт" \
        --text="Сгенерировать наглядный HTML-отчёт с диаграммой?" \
        --no-wrap 2>/dev/null; then

        default_name="net_report_$(date +%Y%m%d_%H%M).html"
        report_path=$(zenity --file-selection --save --confirm-overwrite \
            --title="Сохранить отчёт" --filename="$HOME/$default_name" \
            --file-filter="HTML файлы | *.html" 2>/dev/null) || true

        if [ -n "$report_path" ]; then
            [[ "$report_path" != *.html && "$report_path" != *.HTML ]] && report_path+=".html"
            tmp_html=$(mktemp /tmp/net_report_XXXXXX.html)
            generate_html "$tmp_html" "$TMPDIR_WORK" "$detailed"

            target_dir=$(dirname "$report_path")
            if [ -d "$target_dir" ] && [ -w "$target_dir" ]; then
                if cp -f "$tmp_html" "$report_path" 2>/dev/null; then
                    echo "✅ Отчёт сохранён: $report_path"
                    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] && xdg-open "$report_path" 2>/dev/null || true
                else
                    echo "⚠️ Ошибка копирования. Открываю временную копию..."
                    xdg-open "$tmp_html" 2>/dev/null || true
                fi
            else
                echo "❌ Нет прав на запись в: $target_dir"
                xdg-open "$tmp_html" 2>/dev/null || true
            fi
            rm -f "$tmp_html"
        fi
    fi

    zenity --info --title="Готово" --text="Сканирование завершено." 2>/dev/null || true
    echo -e "\n🏁 Работа завершена. Нажмите Enter для выхода."
    read -r
}

main "$@"
