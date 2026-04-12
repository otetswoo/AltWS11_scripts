# Структура репозитория скриптов

Этот репозиторий организован по категориям для удобной загрузки нужных скриптов с любой машины.

## Категории скриптов

### 🎵 Аудио (`categories/audio/`)
- `04_normalize_volume_audio.sh` — нормализация громкости аудиофайлов по стандарту ITU BS.1770

### 🎬 Видео (`categories/video/`)
- `mp4_compress (antropic).sh` — сжатие видеофайлов MP4

### 🖼️ Изображения (`categories/image/`)
- `02_convert_to_WEBP (Qwen_многопоток).sh` — конвертация изображений в WEBP

### 📄 PDF (`categories/pdf/`)
- `05_pdf_compress_Qwen.sh` — сжатие PDF файлов
- `06_pdf_protect.sh` — защита PDF паролем

### 🌐 Сеть (`categories/network/`)
- `net_analys.sh` — анализ сети

### 🛠️ Утилиты (`categories/utils/`)
- `setup.sh` — базовый скрипт настройки окружения

## Быстрый старт

### Вариант 1: Клонировать весь репозиторий
```bash
git clone <url-репозитория>
cd categories
```

### Вариант 2: Скачать только нужную категорию
Используйте `git sparse-checkout` для загрузки только нужной папки:

```bash
# Инициализация репозитория
git clone --no-checkout <url-репозитория>
cd <имя-репозитория>

# Включение режима sparse-checkout
git sparse-checkout init --cone

# Добавление только нужной категории (например, audio)
git sparse-checkout set categories/audio

# Загрузка файлов
git checkout
```

### Вариант 3: Скачать отдельный скрипт через wget/curl
```bash
# Пример загрузки скрипта для работы с аудио
wget https://raw.githubusercontent.com/<user>/<repo>/main/categories/audio/04_normalize_volume_audio.sh

# Или через curl
curl -O https://raw.githubusercontent.com/<user>/<repo>/main/categories/audio/04_normalize_volume_audio.sh
```

## Установка зависимостей

Большинство скриптов требуют установки следующих пакетов:
```bash
sudo apt install ffmpeg ffprobe zenity imagemagick poppler-utils qpdf
```

## Использование скриптов

1. Сделайте скрипт исполняемым:
   ```bash
   chmod +x script_name.sh
   ```

2. Запустите скрипт:
   ```bash
   ./script_name.sh
   ```

## Примечание

Старая структура с папкой `scripts/` сохраняется для обратной совместимости. Рекомендуется использовать новую структуру с категоризацией.
