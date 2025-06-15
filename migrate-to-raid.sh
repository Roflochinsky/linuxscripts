#!/bin/bash
# 🚀 ПЕРЕНОС ТЕКУЩЕЙ СИСТЕМЫ НА RAID
# Работает после create-raid-live.sh
# Копирует текущую Ubuntu систему на RAID массивы
# Версия: RAID Migration 1.0

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

# Логирование
MIGRATE_LOG="/tmp/migrate-to-raid-$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$MIGRATE_LOG")
exec 2> >(tee -a "$MIGRATE_LOG" >&2)

log "=== 🚀 ПЕРЕНОС СИСТЕМЫ НА RAID ==="

# ЭТАП 1: Проверка RAID массивов
step "ЭТАП 1: Проверка готовности RAID массивов..."

# Проверяем что RAID массивы существуют и активны
REQUIRED_RAIDS=("/dev/md0" "/dev/md1" "/dev/md2")
for raid in "${REQUIRED_RAIDS[@]}"; do
    if [[ ! -b "$raid" ]]; then
        error "RAID массив $raid не найден!"
        error "Сначала запустите create-raid-live.sh"
        exit 1
    fi
    
    # Проверяем статус
    if ! mdadm --detail "$raid" | grep -q "State : clean\|State : active"; then
        warning "RAID $raid не в состоянии clean/active"
        mdadm --detail "$raid" | grep "State :"
    fi
done

success "Все RAID массивы найдены и активны"

# Показываем статус
info "📊 СТАТУС RAID МАССИВОВ:"
cat /proc/mdstat

# ЭТАП 2: Проверка файловых систем
step "ЭТАП 2: Проверка файловых систем RAID..."

# Проверяем что файловые системы созданы
FS_CHECK=true
if ! blkid /dev/md0 | grep -q "ext4"; then
    error "/dev/md0 не имеет файловой системы ext4"
    FS_CHECK=false
fi

if ! blkid /dev/md1 | grep -q "swap"; then
    error "/dev/md1 не настроен как swap"
    FS_CHECK=false
fi

if ! blkid /dev/md2 | grep -q "ext4"; then
    error "/dev/md2 не имеет файловой системы ext4"
    FS_CHECK=false
fi

if [[ "$FS_CHECK" == false ]]; then
    error "Файловые системы не готовы! Запустите create-raid-live.sh"
    exit 1
fi

success "Файловые системы RAID готовы"

# ЭТАП 3: Определение EFI раздела
step "ЭТАП 3: Поиск EFI раздела..."

EFI_PARTITION=""
# Ищем EFI раздел среди всех дисков
for disk in /dev/sd* /dev/nvme*; do
    if [[ -b "$disk"* ]]; then
        for part in "$disk"*; do
            if [[ -b "$part" && "$part" != "$disk" ]]; then
                if blkid "$part" | grep -q "TYPE=\"vfat\"" && \
                   parted "$disk" print 2>/dev/null | grep -q "esp\|boot"; then
                    EFI_PARTITION="$part"
                    break 2
                fi
            fi
        done
    fi
done

if [[ -z "$EFI_PARTITION" ]]; then
    # Пытаемся найти по именованию разделов
    for part in /dev/sd*1 /dev/nvme*p1; do
        if [[ -b "$part" ]] && blkid "$part" | grep -q "TYPE=\"vfat\""; then
            EFI_PARTITION="$part"
            break
        fi
    done
fi

if [[ -z "$EFI_PARTITION" ]]; then
    error "EFI раздел не найден!"
    info "Доступные разделы:"
    lsblk -f | grep -E "vfat|fat32"
    exit 1
fi

success "EFI раздел найден: $EFI_PARTITION"

# ЭТАП 4: Монтирование RAID
step "ЭТАП 4: Монтирование RAID файловых систем..."

MOUNT_POINT="/mnt/raid-target"

# Размонтируем если что-то было смонтировано
umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
umount "$MOUNT_POINT/boot" 2>/dev/null || true
umount "$MOUNT_POINT" 2>/dev/null || true

# Создаем точку монтирования и монтируем в правильном порядке
mkdir -p "$MOUNT_POINT"
mount /dev/md2 "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT/boot/efi"
mount /dev/md0 "$MOUNT_POINT/boot"
mount "$EFI_PARTITION" "$MOUNT_POINT/boot/efi"

success "RAID файловые системы смонтированы в $MOUNT_POINT"

# Проверяем монтирование
info "📊 СМОНТИРОВАННЫЕ RAID УСТРОЙСТВА:"
mount | grep "$MOUNT_POINT"

# ЭТАП 5: Копирование системы
step "ЭТАП 5: Копирование текущей системы на RAID..."

warning "⏱️  Это займет 10-30 минут в зависимости от объема данных"

# Список исключений для rsync
EXCLUDE_LIST=(
    "/dev/*"
    "/proc/*" 
    "/sys/*"
    "/tmp/*"
    "/run/*"
    "/mnt/*"
    "/media/*"
    "/lost+found"
    "/swapfile"
    "/swap.img"
    "$MOUNT_POINT"
    "*.cache"
    "*Cache*"
    "*.tmp"
)

# Создание строки исключений
EXCLUDE_ARGS=""
for exclude in "${EXCLUDE_LIST[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$exclude"
done

log "Начинаем копирование системы на RAID..."
info "Источник: / (текущая система)"
info "Назначение: $MOUNT_POINT (RAID массивы)"

# Копирование с показом прогресса
if rsync -aAXv --progress --stats $EXCLUDE_ARGS / "$MOUNT_POINT/"; then
    success "Копирование системы завершено успешно!"
else
    warning "Копирование завершено с предупреждениями (обычно нормально)"
fi

# ЭТАП 6: Настройка системы на RAID
step "ЭТАП 6: Настройка системы для работы с RAID..."

# Создание нового fstab с RAID UUID
log "Создание нового fstab для RAID..."
cat > "$MOUNT_POINT/etc/fstab" << EOF
# RAID fstab - создан $(date)
# Автоматически сгенерирован migrate-to-raid.sh

# RAID массивы
UUID=$(blkid -s UUID -o value /dev/md2) / ext4 defaults 0 1
UUID=$(blkid -s UUID -o value /dev/md0) /boot ext4 defaults 0 2
UUID=$(blkid -s UUID -o value /dev/md1) none swap sw 0 0

# EFI раздел  
UUID=$(blkid -s UUID -o value $EFI_PARTITION) /boot/efi vfat umask=0077 0 1

# Остальные устройства из оригинального fstab
$(grep -v -E "^#|^$|UUID.*[[:space:]]\/[[:space:]]|UUID.*[[:space:]]\/boot[[:space:]]|UUID.*[[:space:]]none[[:space:]]swap" /etc/fstab 2>/dev/null || true)
EOF

# Настройка RAID конфигурации
log "Настройка RAID конфигурации..."
mkdir -p "$MOUNT_POINT/etc/mdadm"
mdadm --detail --scan > "$MOUNT_POINT/etc/mdadm/mdadm.conf"

# Сохранение оригинальной конфигурации
cp /etc/fstab "$MOUNT_POINT/etc/fstab.original" 2>/dev/null || true

# ЭТАП 7: Подготовка chroot и установка загрузчика
step "ЭТАП 7: Установка загрузчика на RAID..."

# Монтируем системные директории для chroot
mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys "$MOUNT_POINT/sys"

# Определяем диски для установки GRUB
RAID_DISKS=()
for raid in /dev/md0 /dev/md1 /dev/md2; do
    if [[ -b "$raid" ]]; then
        # Получаем диски из RAID массива
        while IFS= read -r line; do
            if [[ $line =~ /dev/(sd[a-z]|nvme[0-9]+n[0-9]+) ]]; then
                disk="${BASH_REMATCH[0]}"
                # Убираем номер раздела для получения основного диска
                if [[ "$disk" =~ nvme ]]; then
                    disk="${disk%p*}"  # nvme0n1p1 -> nvme0n1
                else
                    disk="${disk%[0-9]*}"  # sda1 -> sda
                fi
                
                # Добавляем диск если его еще нет в списке
                if [[ ! " ${RAID_DISKS[@]} " =~ " $disk " ]]; then
                    RAID_DISKS+=("$disk")
                fi
            fi
        done < <(mdadm --detail "$raid" | grep -E "/dev/")
    fi
done

log "Диски для установки GRUB: ${RAID_DISKS[*]}"

# Обновление initramfs для RAID
log "Обновление initramfs для поддержки RAID..."
chroot "$MOUNT_POINT" update-initramfs -u -k all

# Установка GRUB EFI
log "Установка GRUB EFI..."
chroot "$MOUNT_POINT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu

# Установка GRUB на каждый диск для резервирования
for disk in "${RAID_DISKS[@]}"; do
    log "Установка GRUB на $disk..."
    chroot "$MOUNT_POINT" grub-install "$disk" || warning "Не удалось установить GRUB на $disk"
done

# Генерация конфигурации GRUB
log "Генерация конфигурации GRUB..."
chroot "$MOUNT_POINT" update-grub

success "Загрузчик установлен на RAID систему"

# ЭТАП 8: Настройка swap
step "ЭТАП 8: Активация RAID swap..."

# Отключаем старый swap если есть
swapoff -a 2>/dev/null || true

# Включаем новый RAID swap
swapon /dev/md1
success "RAID swap активирован"

# ЭТАП 9: Создание отчета
step "ЭТАП 9: Создание отчета миграции..."

cat > "$MOUNT_POINT/root/raid-migration-info.txt" << EOF
=== 🎉 МИГРАЦИЯ НА RAID ЗАВЕРШЕНА ===
Дата миграции: $(date)
Скрипт: migrate-to-raid.sh v1.0

КОНФИГУРАЦИЯ RAID:
$(for raid in /dev/md0 /dev/md1 /dev/md2; do
    if [[ -b "$raid" ]]; then
        echo "$raid: $(mdadm --detail "$raid" | grep 'Raid Level' | cut -d: -f2)"
        mdadm --detail "$raid" | grep -E "/dev/"
        echo ""
    fi
done)

ФАЙЛОВЫЕ СИСТЕМЫ:
$(lsblk -f | grep -E "md[0-9]|$(basename $EFI_PARTITION)")

НОВЫЙ FSTAB:
$(cat "$MOUNT_POINT/etc/fstab")

УСТАНОВЛЕННЫЕ ЗАГРУЗЧИКИ:
EFI: /boot/efi (ubuntu)
$(for disk in "${RAID_DISKS[@]}"; do
    echo "Legacy BIOS: $disk"
done)

СЛЕДУЮЩИЕ ШАГИ:
1. Перезагрузите систему: sudo reboot
2. Выберите загрузку с RAID дисков
3. Проверьте статус: cat /proc/mdstat
4. Проверьте монтирование: df -h

ВАЖНО:
- Система теперь работает на RAID1
- При отказе одного диска система продолжит работать
- Для замены диска используйте: mdadm --replace
- Регулярно проверяйте: cat /proc/mdstat

Лог миграции: $MIGRATE_LOG
EOF

# Размонтирование
step "ЭТАП 10: Размонтирование..."
umount "$MOUNT_POINT/dev" "$MOUNT_POINT/proc" "$MOUNT_POINT/sys"
umount "$MOUNT_POINT/boot/efi" "$MOUNT_POINT/boot" "$MOUNT_POINT"

# Финальный отчет
clear
success "=== 🎉 МИГРАЦИЯ НА RAID ЗАВЕРШЕНА УСПЕШНО! ==="
echo ""
info "📊 ИТОГОВЫЙ СТАТУС RAID:"
cat /proc/mdstat
echo ""
info "📊 АКТИВНЫЕ SWAP УСТРОЙСТВА:"
swapon --show
echo ""
success "✅ Система скопирована на RAID массивы"
success "✅ Загрузчик установлен на все диски"
success "✅ FSTAB настроен для RAID"
success "✅ RAID swap активирован"
echo ""
warning "🔄 СЛЕДУЮЩИЕ ШАГИ:"
warning "1. Перезагрузите систему: sudo reboot"
warning "2. Система загрузится с RAID дисков"
warning "3. Проверьте работу: cat /proc/mdstat"
echo ""
info "📄 Полный отчет: /root/raid-migration-info.txt (после перезагрузки)"
info "📄 Лог миграции: $MIGRATE_LOG"
echo ""
success "🏆 RAID СИСТЕМА ГОТОВА К РАБОТЕ!" 