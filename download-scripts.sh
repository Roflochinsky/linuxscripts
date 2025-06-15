#!/bin/bash
# 📥 АВТОМАТИЧЕСКОЕ СКАЧИВАНИЕ RAID СКРИПТОВ
# Скачивает актуальные скрипты с GitHub
# Версия: Auto Downloader 1.0

set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Универсальная функция конвертации Windows -> Unix формата
convert_to_unix() {
    local file="$1"
    
    # Проверяем нужна ли конвертация
    if file "$file" | grep -q "CRLF\|CR line terminators"; then
        log "   🔄 Конвертация из Windows формата в Unix..."
        
        # Пробуем разные способы конвертации
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix "$file" 2>/dev/null
            log "   ✅ Конвертация выполнена (dos2unix)"
        elif command -v sed >/dev/null 2>&1; then
            sed -i 's/\r$//' "$file" 2>/dev/null
            log "   ✅ Конвертация выполнена (sed)"
        elif command -v tr >/dev/null 2>&1; then
            tr -d '\r' < "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
            log "   ✅ Конвертация выполнена (tr)"
        else
            warning "   ⚠️  Не удалось найти инструменты для конвертации"
            warning "   ⚠️  Установите dos2unix: sudo apt-get install dos2unix"
        fi
    else
        log "   ✅ Файл уже в Unix формате"
    fi
}

log "=== 📥 СКАЧИВАНИЕ UBUNTU RAID СКРИПТОВ ==="

# Настройки
GITHUB_REPO="https://raw.githubusercontent.com/Roflochinsky/linuxscripts/main"
LOCAL_DIR="$HOME/raid-scripts"
TEMP_DIR="/tmp/raid-scripts-download"

# Проверка интернета
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    error "❌ Нет интернета! Используйте локальные скрипты с флешки"
    exit 1
fi

# Создание директории
mkdir -p "$LOCAL_DIR"
mkdir -p "$TEMP_DIR"

log "📁 Скачивание в: $LOCAL_DIR"

# Список скриптов для скачивания
SCRIPTS=(
    "create-raid-live.sh"
    "migrate-to-raid.sh"
    "backup-raid-system-simple.sh"
    "backup-essential-only.sh"
)

cd "$TEMP_DIR"

# Скачивание скриптов
for script in "${SCRIPTS[@]}"; do
    log "📥 Скачивание $script..."
    
    if wget -q "$GITHUB_REPO/$script" -O "$script"; then
        # Автоматическая конвертация формата файла
        convert_to_unix "$script"
        
        chmod +x "$script"
        log "   ✅ $script скачан и готов к использованию"
    else
        error "   ❌ Ошибка скачивания $script"
        continue
    fi
done

# Проверка что скрипты скачались
DOWNLOADED=0
for script in "${SCRIPTS[@]}"; do
    if [[ -f "$script" && -x "$script" ]]; then
        ((DOWNLOADED++))
    fi
done

if [[ $DOWNLOADED -eq 0 ]]; then
    error "❌ Ни один скрипт не скачался!"
    exit 1
fi

# Копирование в финальную директорию  
log "📂 Установка скриптов..."
cp *.sh "$LOCAL_DIR/"

# Дополнительная проверка и конвертация установленных скриптов
log "🔄 Проверка формата установленных скриптов..."
for script in "$LOCAL_DIR"/*.sh; do
    if [[ -f "$script" ]]; then
        convert_to_unix "$script"
    fi
done

# Создание README
cat > "$LOCAL_DIR/README.md" << 'EOF'
# 🚀 Ubuntu RAID Scripts

Автоматически скачанные скрипты для работы с RAID системами.

## 📋 Доступные скрипты:

### 1️⃣ create-raid-live.sh
Создание RAID структуры на живой системе
```bash
sudo ./create-raid-live.sh
```

### 2️⃣ migrate-to-raid.sh  
Перенос текущей системы на RAID
```bash
sudo ./migrate-to-raid.sh
```

### 3️⃣ backup-raid-system-simple.sh
Компактный backup RAID системы (100-500MB)
```bash
sudo ./backup-raid-system-simple.sh
```

### 4️⃣ backup-essential-only.sh
Минимальный backup только критических данных (50-200MB)
```bash
sudo ./backup-essential-only.sh
```

## 🎯 Быстрый старт:

### Создание RAID:
```bash
sudo ./create-raid-live.sh
sudo ./migrate-to-raid.sh
sudo reboot
```

### Backup системы:
```bash
sudo ./backup-essential-only.sh
```

## 🔄 Обновление скриптов:
```bash
./download-scripts.sh
```
EOF

# Создание скрипта обновления
cat > "$LOCAL_DIR/update.sh" << 'UPDATE_EOF'
#!/bin/bash
# Обновление скриптов до последней версии
cd "$(dirname "$0")"
        wget -q https://raw.githubusercontent.com/Roflochinsky/linuxscripts/main/download-scripts.sh -O /tmp/download-scripts.sh
chmod +x /tmp/download-scripts.sh
/tmp/download-scripts.sh
UPDATE_EOF

chmod +x "$LOCAL_DIR/update.sh"

# Очистка
rm -rf "$TEMP_DIR"

# Итоговый отчет
clear
log "=== 🎉 СКРИПТЫ УСПЕШНО СКАЧАНЫ! ==="
echo ""
info "📂 Расположение: $LOCAL_DIR"
info "📋 Скачано скриптов: $DOWNLOADED из ${#SCRIPTS[@]}"
echo ""
log "📋 ДОСТУПНЫЕ КОМАНДЫ:"
echo ""
echo "  🔧 Создать RAID:"
echo "     cd $LOCAL_DIR"
echo "     sudo ./create-raid-live.sh"
echo "     sudo ./migrate-to-raid.sh"
echo ""
echo "  💾 Сделать backup:"
echo "     sudo ./backup-essential-only.sh"
echo ""
echo "  🔄 Обновить скрипты:"
echo "     ./update.sh"
echo ""
warning "💡 СОВЕТ: Скопируйте скрипты на флешку для аварийного восстановления!"
echo "     cp $LOCAL_DIR/*.sh /media/usb/"
echo ""
log "🏆 Готово к использованию!" 
