# AltWS11_scripts
Репозиторий скриптов для Альт

## 📁 Структура репозитория

Скрипты организованы по категориям в папке `categories/` для удобной загрузки только нужных инструментов:

- **🎵 [Аудио](categories/audio/)** — нормализация громкости аудиофайлов
- **🎬 [Видео](categories/video/)** — сжатие видео MP4
- **🖼️ [Изображения](categories/image/)** — конвертация в WEBP
- **📄 [PDF](categories/pdf/)** — сжатие и защита PDF файлов
- **🌐 [Сеть](categories/network/)** — анализ сети
- **🛠️ [Утилиты](categories/utils/)** — вспомогательные скрипты

Подробное описание и инструкции по использованию см. в файле [CATEGORIES_README.md](CATEGORIES_README.md).

## 🚀 Быстрый старт

### Скачать только нужную категорию (например, аудио):
```bash
git clone --no-checkout <url-репозитория>
cd <имя-репозитория>
git sparse-checkout init --cone
git sparse-checkout set categories/audio
git checkout
```

### Или скачать весь репозиторий:
```bash
git clone <url-репозитория>
cd categories
```

---
*Старая структура с папкой `scripts/` сохраняется для обратной совместимости.*
