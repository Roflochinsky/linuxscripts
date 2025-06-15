#!/bin/bash
# 📦 ПРОСТОЙ BACKUP RAID СИСТЕМЫ
# Создает компактный backup уже настроенной RAID системы
# Размер: ~100-500МБ вместо нескольких ГБ
# Версия: RAID Simple Backup 1.0

set -e

# Цвета и логирование
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[❌ ERROR]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[⚠️  WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[ℹ️  INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✅ SUCCESS]${NC} $1"; }
step() { echo -e "${PURPLE}[🔧 STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   error "Запустите с sudo: sudo $0"
   exit 1
fi

REAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo "unknown")}

log "=== 📦 ПРОСТОЙ BACKUP RAID СИСТЕМЫ ==="

# Поиск флешки/внешнего диска
find_backup_location() {
    local backup_paths=(
        "/media/$REAL_USER"
        "/mnt/usb"
        "/media/usb"
        "/run/media/$REAL_USER"
    )
    
    for base_path in "${backup_paths[@]}"; do
        if [[ -d "$base_path" ]]; then
            for path in "$base_path"/*; do
                if [[ -d "$path" && -w "$path" ]]; then
                    # Проверяем что это не системный диск
                    if ! mountpoint -q "$path" || ! df "$path" | grep -q "/dev/md"; then
                        local free_space=$(df --output=avail "$path" | tail -1)
                        if [[ $free_space -gt 1048576 ]]; then  # >1GB свободно
                            echo "$path"
                            return 0
                        fi
                    fi
                fi
            done
        fi
    done
    
    return 1
}

BACKUP_LOCATION=$(find_backup_location)
if [[ -z "$BACKUP_LOCATION" ]]; then
    error "Место для backup не найдено!"
    info "Подключите флешку или внешний диск"
    info "Доступные устройства:"
    lsblk -o NAME,SIZE,MOUNTPOINT | grep -E "/media|/mnt"
    exit 1
fi

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_LOCATION/raid-backup-$DATE"
LOG_FILE="$BACKUP_DIR/backup.log"

success "Место для backup: $BACKUP_LOCATION"
success "Backup будет создан в: $BACKUP_DIR"

# Проверка свободного места
FREE_SPACE=$(df --output=avail "$BACKUP_LOCATION" | tail -1)
FREE_SPACE_GB=$((FREE_SPACE / 1024 / 1024))

if [[ $FREE_SPACE_GB -lt 1 ]]; then
    error "Недостаточно места! Требуется минимум 1GB, доступно: ${FREE_SPACE_GB}GB"
    exit 1
fi

info "Свободного места: ${FREE_SPACE_GB}GB"

# Создание структуры backup
mkdir -p "$BACKUP_DIR"/{configs,raid-info,system-data,logs}
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# ЭТАП 1: RAID конфигурация (КРИТИЧНО!)
step "ЭТАП 1: Backup RAID конфигурации..."

# Проверяем что система на RAID
if [[ ! -b /dev/md0 || ! -b /dev/md1 || ! -b /dev/md2 ]]; then
    error "RAID массивы не найдены! Система не на RAID?"
    info "Доступные устройства:"
    lsblk
    exit 1
fi

# Детальная информация о RAID
{
    echo "=== RAID BACKUP $(date) ==="
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo ""
    
    echo "=== RAID STATUS ==="
    cat /proc/mdstat
    echo ""
    
    echo "=== RAID DETAILS ==="
    for md in /dev/md{0,1,2}; do
        if [[ -b "$md" ]]; then
            echo "=== $md ==="
            mdadm --detail "$md"
            echo ""
        fi
    done
    
    echo "=== MDADM CONFIG ==="
    mdadm --detail --scan
    echo ""
    
    echo "=== BLOCK DEVICES ==="
    lsblk -f
    echo ""
    
    echo "=== MOUNTS ==="
    mount | grep -E "md[0-9]"
    
} > "$BACKUP_DIR/raid-info/raid-config.txt"

# Сохранение mdadm.conf
mdadm --detail --scan > "$BACKUP_DIR/raid-info/mdadm.conf"

# Таблицы разделов всех дисков
log "Сохранение схем разделов..."
for disk in /dev/sd[a-z] /dev/nvme*n[0-9]; do
    if [[ -b "$disk" ]] && ! [[ "$disk" =~ [0-9]$ ]]; then
        disk_name=$(basename "$disk")
        log "Backup разделов $disk..."
        
        sfdisk -d "$disk" > "$BACKUP_DIR/raid-info/${disk_name}-partitions.sfdisk" 2>/dev/null
        sgdisk --backup="$BACKUP_DIR/raid-info/${disk_name}-gpt.backup" "$disk" 2>/dev/null || true
        
        {
            echo "=== PARTITION INFO $disk ==="
            parted "$disk" print 2>/dev/null || fdisk -l "$disk" 2>/dev/null
            echo ""
        } >> "$BACKUP_DIR/raid-info/partitions-info.txt"
    fi
done

success "RAID конфигурация сохранена"

# ЭТАП 2: Системные конфигурации
step "ЭТАП 2: Backup системных конфигураций..."

# fstab и UUID (КРИТИЧНО!)
cp /etc/fstab "$BACKUP_DIR/configs/fstab"
{
    echo "=== CURRENT FSTAB ==="
    cat /etc/fstab
    echo ""
    echo "=== ALL UUIDs ==="
    blkid
    echo ""
    echo "=== RAID UUIDs ==="
    blkid | grep -E "md[0-9]"
} > "$BACKUP_DIR/configs/fstab-info.txt"

# Сетевые настройки
log "Backup сетевых настроек..."
mkdir -p "$BACKUP_DIR/configs/network"
cp /etc/hostname "$BACKUP_DIR/configs/network/" 2>/dev/null || true
cp /etc/hosts "$BACKUP_DIR/configs/network/" 2>/dev/null || true

# Netplan конфигурация
if [[ -d /etc/netplan ]]; then
    tar -czf "$BACKUP_DIR/configs/network/netplan.tar.gz" /etc/netplan/ 2>/dev/null
fi

# SSH настройки (только конфигурация)
if [[ -d /etc/ssh ]]; then
    mkdir -p "$BACKUP_DIR/configs/ssh"
    cp /etc/ssh/sshd_config "$BACKUP_DIR/configs/ssh/" 2>/dev/null || true
    cp /etc/ssh/ssh_host_*_key.pub "$BACKUP_DIR/configs/ssh/" 2>/dev/null || true
fi

# Список установленных пакетов
log "Создание списка пакетов..."
dpkg --get-selections > "$BACKUP_DIR/configs/packages-installed.txt"
apt-mark showauto > "$BACKUP_DIR/configs/packages-auto.txt"

# Snap пакеты
snap list > "$BACKUP_DIR/configs/snap-packages.txt" 2>/dev/null || echo "Snap не установлен" > "$BACKUP_DIR/configs/snap-packages.txt"

# ЭТАП 3: Пользовательские конфигурации (СЖАТО)
step "ЭТАП 3: Backup пользовательских конфигураций..."

# Только конфигурационные файлы пользователей
if [[ -d /home ]]; then
    log "Архивация пользовательских конфигураций..."
    
    tar --exclude='*/.cache' --exclude='*/Cache*' --exclude='*/.tmp' \
        --exclude='*/.local/share/Trash' --exclude='*/Downloads/*' \
        --exclude='*/.steam' --exclude='*/.mozilla/firefox/*/Cache*' \
        --exclude='*/snap' --exclude='*/.npm' --exclude='*/.gradle' \
        -czf "$BACKUP_DIR/configs/user-configs.tar.gz" \
        /home/*/.*rc /home/*/.config /home/*/.ssh /home/*/.gnupg \
        /home/*/Documents /home/*/Desktop /home/*/.bashrc \
        /home/*/.profile /home/*/.vimrc 2>/dev/null || warning "Частичная архивация пользователей"
fi

# Root конфигурации
if [[ -d /root ]]; then
    tar --exclude='*/.cache' --exclude='*/.tmp' \
        -czf "$BACKUP_DIR/configs/root-configs.tar.gz" \
        /root/.*rc /root/.config /root/.ssh /root/.gnupg \
        /root/.bashrc /root/.profile /root/.vimrc 2>/dev/null || warning "Частичная архивация root"
fi

# ЭТАП 4: Дополнительные системные данные  
step "ЭТАП 4: Backup дополнительных данных..."

# Cron задачи
log "Backup планировщика задач..."
mkdir -p "$BACKUP_DIR/system-data/cron"
cp -r /etc/cron* "$BACKUP_DIR/system-data/cron/" 2>/dev/null || true
crontab -l > "$BACKUP_DIR/system-data/cron/root-crontab.txt" 2>/dev/null || echo "No root crontab" > "$BACKUP_DIR/system-data/cron/root-crontab.txt"

# Systemd сервисы (только кастомные)
log "Backup systemd сервисов..."
mkdir -p "$BACKUP_DIR/system-data/systemd"
if [[ -d /etc/systemd/system ]]; then
    tar -czf "$BACKUP_DIR/system-data/systemd/custom-services.tar.gz" /etc/systemd/system/ 2>/dev/null
fi

# Важные конфигурации из /etc
log "Backup критических конфигураций /etc..."
tar --exclude='/etc/ssl/private' --exclude='/etc/shadow*' \
    -czf "$BACKUP_DIR/system-data/etc-configs.tar.gz" \
    /etc/sudoers* /etc/group* /etc/passwd* /etc/default \
    /etc/security /etc/pam.d /etc/logrotate.d /etc/apt 2>/dev/null || warning "Частичная архивация /etc"

# ЭТАП 5: Скрипты восстановления
step "ЭТАП 5: Создание скриптов восстановления..."

# Скрипт информации о backup
cat > "$BACKUP_DIR/show-info.sh" << 'EOF'
#!/bin/bash
# Показать информацию о backup

BACKUP_DIR="$(dirname "$(realpath "$0")")"
echo "=== RAID BACKUP ИНФОРМАЦИЯ ==="
echo "Расположение: $BACKUP_DIR"
echo ""

if [[ -f "$BACKUP_DIR/raid-info/raid-config.txt" ]]; then
    echo "=== ОРИГИНАЛЬНАЯ RAID КОНФИГУРАЦИЯ ==="
    head -30 "$BACKUP_DIR/raid-info/raid-config.txt"
    echo ""
fi

echo "=== РАЗМЕРЫ BACKUP ==="
du -sh "$BACKUP_DIR"/* 2>/dev/null
echo ""
echo "Общий размер: $(du -sh "$BACKUP_DIR" | cut -f1)"
EOF

chmod +x "$BACKUP_DIR/show-info.sh"

# Скрипт быстрого восстановления конфигураций
cat > "$BACKUP_DIR/restore-configs.sh" << 'EOF'
#!/bin/bash
# Быстрое восстановление конфигураций на уже настроенную RAID систему

set -e
if [[ $EUID -ne 0 ]]; then
   echo "Запустите с sudo"
   exit 1
fi

BACKUP_DIR="$(dirname "$(realpath "$0")")"
echo "Восстановление конфигураций из $BACKUP_DIR..."

# Восстановление пользовательских конфигураций
if [[ -f "$BACKUP_DIR/configs/user-configs.tar.gz" ]]; then
    echo "Восстановление пользовательских конфигураций..."
    tar -xzf "$BACKUP_DIR/configs/user-configs.tar.gz" -C / 2>/dev/null
fi

if [[ -f "$BACKUP_DIR/configs/root-configs.tar.gz" ]]; then
    echo "Восстановление root конфигураций..."
    tar -xzf "$BACKUP_DIR/configs/root-configs.tar.gz" -C / 2>/dev/null
fi

# Восстановление системных конфигураций
if [[ -f "$BACKUP_DIR/system-data/etc-configs.tar.gz" ]]; then
    echo "Восстановление системных конфигураций..."
    tar -xzf "$BACKUP_DIR/system-data/etc-configs.tar.gz" -C / 2>/dev/null
fi

# Восстановление пакетов
if [[ -f "$BACKUP_DIR/configs/packages-installed.txt" ]]; then
    echo "Установка пакетов..."
    dpkg --set-selections < "$BACKUP_DIR/configs/packages-installed.txt"
    apt-get dselect-upgrade -y
    
    if [[ -f "$BACKUP_DIR/configs/packages-auto.txt" ]]; then
        apt-mark auto $(cat "$BACKUP_DIR/configs/packages-auto.txt")
    fi
fi

echo "✅ Восстановление конфигураций завершено"
echo "Перезагрузитесь для применения всех изменений"
EOF

chmod +x "$BACKUP_DIR/restore-configs.sh"

# ЭТАП 6: Создание README и финализация
step "ЭТАП 6: Создание документации..."

TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)

cat > "$BACKUP_DIR/README.txt" << EOF
=== 📦 ПРОСТОЙ RAID BACKUP ===
Дата создания: $(date)
Размер: $TOTAL_SIZE
Исходная система: $(lsb_release -d | cut -f2) 
Ядро: $(uname -r)
Hostname: $(hostname)

=== КОНФИГУРАЦИЯ RAID ===
$(cat /proc/mdstat | grep -E "md[0-9]")

=== СОДЕРЖИМОЕ BACKUP ===
configs/                - Системные и пользовательские конфигурации
  ├── fstab            - Таблица монтирования  
  ├── packages-*.txt   - Списки установленных пакетов
  ├── user-configs.tar.gz - Пользовательские настройки
  └── network/         - Сетевые настройки

raid-info/              - КРИТИЧЕСКАЯ информация о RAID
  ├── mdadm.conf       - Конфигурация RAID
  ├── raid-config.txt  - Полная информация о RAID
  └── *-partitions.*   - Схемы разделов дисков

system-data/            - Дополнительные системные данные
  ├── cron/            - Задачи планировщика
  ├── systemd/         - Системные сервисы
  └── etc-configs.tar.gz - Важные конфигурации

=== ИСПОЛЬЗОВАНИЕ ===
1. Просмотр информации:    ./show-info.sh
2. Восстановление конфигов: ./restore-configs.sh
3. Полное восстановление:  Используйте create-raid-live.sh + migrate-to-raid.sh

=== ТИПЫ ВОССТАНОВЛЕНИЯ ===
БЫСТРОЕ (на существующую RAID систему):
  - Запустите restore-configs.sh
  - Восстанавливает настройки и пакеты
  - Время: 5-15 минут

ПОЛНОЕ (на новое железо):  
  1. Используйте create-raid-live.sh
  2. Используйте migrate-to-raid.sh
  3. Запустите restore-configs.sh
  - Время: 30-60 минут

=== ВАЖНЫЕ ФАЙЛЫ ===
raid-info/mdadm.conf     - Для воссоздания RAID
configs/fstab            - Таблица монтирования
configs/packages-*.txt   - Для установки пакетов

Размер: $TOTAL_SIZE (оптимизирован для быстрого backup)
EOF

# Контрольные суммы для проверки целостности
find "$BACKUP_DIR" -type f -name "*.conf" -o -name "*.txt" -o -name "*.tar.gz" | \
    xargs md5sum > "$BACKUP_DIR/checksums.md5" 2>/dev/null

# Финализация
sync
FINAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)

# Итоговый отчет
clear
success "=== 📦 ПРОСТОЙ RAID BACKUP ЗАВЕРШЕН! ==="
echo ""
info "📊 РЕЗУЛЬТАТ:"
echo "   💾 Размер backup: $FINAL_SIZE"
echo "   📍 Расположение: $BACKUP_DIR"
echo "   ⚡ Время создания: $(date)"
echo ""
success "✅ RAID конфигурация сохранена"
success "✅ Системные настройки заархивированы"  
success "✅ Пользовательские конфигурации сохранены"
success "✅ Списки пакетов созданы"
echo ""
info "📋 ИСПОЛЬЗОВАНИЕ:"
info "   👀 Информация: $BACKUP_DIR/show-info.sh"
info "   🔧 Восстановление: $BACKUP_DIR/restore-configs.sh"
info "   📖 Подробности: $BACKUP_DIR/README.txt"
echo ""
warning "💾 СОХРАНИТЕ BACKUP В БЕЗОПАСНОМ МЕСТЕ!"
success "🏆 Backup готов к использованию!" 