#!/bin/bash
# 🚀 СОЗДАНИЕ RAID НА ЖИВОЙ UBUNTU СИСТЕМЕ
# Автоматическое определение дисков и создание RAID1
# Версия: Live RAID Creator 1.0

set -e

# Цвета и логирование
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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
RAID_LOG="/tmp/create-raid-$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$RAID_LOG")
exec 2> >(tee -a "$RAID_LOG" >&2)

log "=== 🚀 СОЗДАНИЕ RAID НА ЖИВОЙ UBUNTU СИСТЕМЕ ==="

# ЭТАП 1: Автоматическое определение дисков
step "ЭТАП 1: Поиск подходящих дисков..."

# Получение списка дисков (исключаем загрузочные и малые)
declare -A DISKS
declare -A DISK_SIZES
declare -A DISK_MODELS
declare -A DISK_SIZES_BYTES

while IFS= read -r line; do
    if [[ $line =~ ^(sd[a-z]|nvme[0-9]+n[0-9]+)[[:space:]]+([0-9.]+[KMGT]?)[[:space:]]+disk[[:space:]]+(.*)$ ]]; then
        disk="${BASH_REMATCH[1]}"
        size="${BASH_REMATCH[2]}"
        model="${BASH_REMATCH[3]}"
        
        # Получаем размер в байтах для точного сравнения
        size_bytes=$(lsblk -b -d -n -o SIZE "/dev/$disk" 2>/dev/null || echo "0")
        
        # Пропускаем системные диски, USB, CD/DVD и диски меньше 64GB
        if [[ ! "$model" =~ (USB|Flash|DataTraveler|CD|DVD) && 
              "$disk" != "sr0" && 
              "$size_bytes" -gt 68719476736 ]]; then  # 64GB в байтах
            
            # Проверяем что диск не используется системой
            if ! mount | grep -q "/dev/$disk"; then
                DISKS["/dev/$disk"]="$size"
                DISK_SIZES["/dev/$disk"]="$size"
                DISK_MODELS["/dev/$disk"]="$model"
                DISK_SIZES_BYTES["/dev/$disk"]="$size_bytes"
            fi
        fi
    fi
done < <(lsblk -d -n -o NAME,SIZE,TYPE,MODEL)

if [[ ${#DISKS[@]} -eq 0 ]]; then
    error "Подходящие диски не найдены!"
    info "Требования: минимум 64GB, не системные, не USB"
    info "Доступные устройства:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL
    exit 1
fi

# Показ найденных дисков
info "📊 НАЙДЕННЫЕ ДИСКИ ДЛЯ RAID:"
echo "┌─────────────┬─────────────┬──────────────────┬─────────────┐"
echo "│ УСТРОЙСТВО  │   РАЗМЕР    │      МОДЕЛЬ      │   СТАТУС    │"
echo "├─────────────┼─────────────┼──────────────────┼─────────────┤"

for disk in "${!DISKS[@]}"; do
    size="${DISK_SIZES[$disk]}"
    model="${DISK_MODELS[$disk]:0:16}"
    status="✅ Свободен"
    printf "│ %-11s │ %-11s │ %-16s │ %-11s │\n" "$disk" "$size" "$model" "$status"
done

echo "└─────────────┴─────────────┴──────────────────┴─────────────┘"

# Группировка дисков по размеру (с допуском 1GB)
declare -A SIZE_GROUPS
for disk in "${!DISKS[@]}"; do
    size_bytes="${DISK_SIZES_BYTES[$disk]}"
    # Округляем до ближайшего GB для группировки
    size_gb=$((size_bytes / 1073741824))
    SIZE_GROUPS["$size_gb"]+="$disk "
done

# Поиск подходящих пар
SUITABLE_PAIRS=()
for size_gb in "${!SIZE_GROUPS[@]}"; do
    disks=(${SIZE_GROUPS[$size_gb]})
    if [[ ${#disks[@]} -ge 2 ]]; then
        # Проверяем что размеры действительно близки (разница < 5%)
        for ((i=0; i<${#disks[@]}-1; i++)); do
            for ((j=i+1; j<${#disks[@]}; j++)); do
                disk1="${disks[i]}"
                disk2="${disks[j]}"
                size1="${DISK_SIZES_BYTES[$disk1]}"
                size2="${DISK_SIZES_BYTES[$disk2]}"
                
                # Вычисляем разность в процентах
                if [[ $size1 -gt $size2 ]]; then
                    diff=$((($size1 - $size2) * 100 / $size1))
                else
                    diff=$((($size2 - $size1) * 100 / $size2))
                fi
                
                if [[ $diff -lt 5 ]]; then  # Разница менее 5%
                    SUITABLE_PAIRS+=("$disk1|$disk2|${DISK_SIZES[$disk1]}")
                fi
            done
        done
    fi
done

if [[ ${#SUITABLE_PAIRS[@]} -eq 0 ]]; then
    error "Не найдены пары дисков подходящего размера для RAID!"
    info "Требуется минимум 2 диска близкого размера (разница < 5%)"
    exit 1
fi

# Показ рекомендуемых пар
info "🏆 НАЙДЕННЫЕ ПАРЫ ДИСКОВ ДЛЯ RAID1:"
for i in "${!SUITABLE_PAIRS[@]}"; do
    IFS='|' read -r disk1 disk2 size <<< "${SUITABLE_PAIRS[$i]}"
    echo "  $((i+1)). $disk1 + $disk2 ($size каждый)"
done

# Автоматическая рекомендация лучшей пары (самые большие диски)
BEST_PAIR="${SUITABLE_PAIRS[0]}"
BEST_SIZE=0
for pair in "${SUITABLE_PAIRS[@]}"; do
    IFS='|' read -r disk1 disk2 size <<< "$pair"
    size_bytes="${DISK_SIZES_BYTES[$disk1]}"
    if [[ $size_bytes -gt $BEST_SIZE ]]; then
        BEST_PAIR="$pair"
        BEST_SIZE=$size_bytes
    fi
done

IFS='|' read -r REC_DISK1 REC_DISK2 REC_SIZE <<< "$BEST_PAIR"

success "🎯 РЕКОМЕНДАЦИЯ (самые большие диски):"
echo "   ДИСК 1: $REC_DISK1"
echo "   ДИСК 2: $REC_DISK2"
echo "   РАЗМЕР: $REC_SIZE каждый"
echo ""

# Подтверждение выбора
read -p "Использовать рекомендованную пару? (Y/n): " confirm
if [[ "$confirm" =~ ^[nN] ]]; then
    echo "Выберите пару дисков:"
    for i in "${!SUITABLE_PAIRS[@]}"; do
        IFS='|' read -r disk1 disk2 size <<< "${SUITABLE_PAIRS[$i]}"
        echo "  $((i+1)). $disk1 + $disk2"
    done
    read -p "Введите номер пары (1-${#SUITABLE_PAIRS[@]}): " choice
    if [[ "$choice" -ge 1 && "$choice" -le ${#SUITABLE_PAIRS[@]} ]]; then
        SELECTED_PAIR="${SUITABLE_PAIRS[$((choice-1))]}"
        IFS='|' read -r DISK1 DISK2 _ <<< "$SELECTED_PAIR"
    else
        error "Неверный выбор!"
        exit 1
    fi
else
    DISK1="$REC_DISK1"
    DISK2="$REC_DISK2"
fi

# Расчет размеров разделов
DISK_SIZE_BYTES="${DISK_SIZES_BYTES[$DISK1]}"
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1073741824))

warning "📊 ПЛАНИРУЕМАЯ СХЕМА РАЗДЕЛОВ:"
echo ""
echo "💾 ДИСК 1 ($DISK1):"
echo "   sda1: 512MB  - EFI boot"
echo "   sda2: 1GB    - /boot (RAID1)"
echo "   sda3: 32GB   - swap (RAID1)"
echo "   sda4: $((DISK_SIZE_GB - 33))GB    - / (RAID1)"
echo ""
echo "💾 ДИСК 2 ($DISK2):"
echo "   sdb1: 1GB    - /boot (RAID1)"
echo "   sdb2: 32GB   - swap (RAID1)"
echo "   sdb3: $((DISK_SIZE_GB - 33))GB    - / (RAID1)"
echo ""
echo "🔄 RAID массивы:"
echo "   md0: /boot (RAID1)"
echo "   md1: swap (RAID1)"
echo "   md2: / (RAID1)"
echo ""

warning "❗ ВНИМАНИЕ! ВСЕ ДАННЫЕ НА ДИСКАХ $DISK1 И $DISK2 БУДУТ УДАЛЕНЫ!"
read -p "Введите 'YES DELETE ALL DATA' для продолжения: " final_confirm

if [[ "$final_confirm" != "YES DELETE ALL DATA" ]]; then
    log "Операция отменена пользователем"
    exit 0
fi

# ЭТАП 2: Остановка существующих RAID массивов
step "ЭТАП 2: Подготовка дисков..."

# Останавливаем все возможные RAID массивы
for md in /dev/md{0,1,2,125,126,127}; do
    if [[ -b "$md" ]]; then
        log "Останавливаем $md"
        mdadm --stop "$md" 2>/dev/null || true
    fi
done

# Размонтируем разделы если они примонтированы
for disk in "$DISK1" "$DISK2"; do
    for part in "${disk}"*; do
        if [[ -b "$part" && "$part" != "$disk" ]]; then
            umount "$part" 2>/dev/null || true
            mdadm --zero-superblock "$part" 2>/dev/null || true
        fi
    done
done

# ЭТАП 3: Создание разделов
step "ЭТАП 3: Создание схемы разделов..."

# Определяем тип именования разделов
if [[ "$DISK1" =~ nvme ]]; then
    D1P1="${DISK1}p1"; D1P2="${DISK1}p2"; D1P3="${DISK1}p3"; D1P4="${DISK1}p4"
else
    D1P1="${DISK1}1"; D1P2="${DISK1}2"; D1P3="${DISK1}3"; D1P4="${DISK1}4"
fi

if [[ "$DISK2" =~ nvme ]]; then
    D2P1="${DISK2}p1"; D2P2="${DISK2}p2"; D2P3="${DISK2}p3"
else
    D2P1="${DISK2}1"; D2P2="${DISK2}2"; D2P3="${DISK2}3"
fi

# Создание разделов на первом диске
log "Создание разделов на $DISK1..."
parted -s "$DISK1" mklabel gpt
parted -s "$DISK1" mkpart primary fat32 1MiB 513MiB        # EFI
parted -s "$DISK1" mkpart primary ext4 513MiB 1537MiB      # /boot
parted -s "$DISK1" mkpart primary linux-swap 1537MiB 34GiB # swap (32GB + запас)
parted -s "$DISK1" mkpart primary ext4 34GiB 100%          # /
parted -s "$DISK1" set 1 esp on

# Создание разделов на втором диске  
log "Создание разделов на $DISK2..."
parted -s "$DISK2" mklabel gpt
parted -s "$DISK2" mkpart primary ext4 1MiB 1025MiB        # /boot
parted -s "$DISK2" mkpart primary linux-swap 1025MiB 33GiB # swap
parted -s "$DISK2" mkpart primary ext4 33GiB 100%          # /

# Ожидание обновления разделов
sleep 5
partprobe "$DISK1" "$DISK2"
sleep 3

success "Разделы созданы:"
success "$DISK1: $D1P1(EFI) $D1P2(/boot) $D1P3(swap) $D1P4(/)"
success "$DISK2: $D2P1(/boot) $D2P2(swap) $D2P3(/)"

# ЭТАП 4: Создание RAID массивов
step "ЭТАП 4: Создание RAID1 массивов..."

log "Создание md0 для /boot..."
mdadm --create /dev/md0 --level=1 --raid-devices=2 "$D1P2" "$D2P1" --metadata=1.2 --force

log "Создание md1 для swap..."
mdadm --create /dev/md1 --level=1 --raid-devices=2 "$D1P3" "$D2P2" --metadata=1.2 --force

log "Создание md2 для /..."
mdadm --create /dev/md2 --level=1 --raid-devices=2 "$D1P4" "$D2P3" --metadata=1.2 --force

sleep 5

# Проверяем что RAID массивы созданы
success "RAID массивы созданы:"
cat /proc/mdstat

# ЭТАП 5: Создание файловых систем
step "ЭТАП 5: Создание файловых систем..."

log "Создание EFI файловой системы..."
mkfs.vfat -F32 "$D1P1"

log "Создание /boot файловой системы..."
mkfs.ext4 -F /dev/md0

log "Создание swap..."
mkswap /dev/md1

log "Создание корневой файловой системы..."
mkfs.ext4 -F /dev/md2

success "Все файловые системы созданы!"

# ЭТАП 6: Настройка системы
step "ЭТАП 6: Настройка RAID конфигурации..."

# Создание mdadm.conf
log "Создание конфигурации RAID..."
mkdir -p /etc/mdadm
mdadm --detail --scan > /etc/mdadm/mdadm.conf

# Создание временного fstab для справки
cat > /tmp/new-fstab << EOF
# Новый fstab для RAID системы
# Скопируйте в /etc/fstab после монтирования
UUID=$(blkid -s UUID -o value /dev/md2) / ext4 defaults 0 1
UUID=$(blkid -s UUID -o value /dev/md0) /boot ext4 defaults 0 2
UUID=$(blkid -s UUID -o value $D1P1) /boot/efi vfat umask=0077 0 1
UUID=$(blkid -s UUID -o value /dev/md1) none swap sw 0 0
EOF

# ЭТАП 7: Создание отчета
step "ЭТАП 7: Создание отчета..."

cat > /tmp/raid-setup-complete.txt << EOF
=== 🎉 RAID СИСТЕМА СОЗДАНА УСПЕШНО! ===
Дата создания: $(date)
Скрипт: create-raid-live.sh v1.0

КОНФИГУРАЦИЯ ДИСКОВ:
Диск 1: $DISK1 ($(lsblk -d -n -o SIZE $DISK1))
Диск 2: $DISK2 ($(lsblk -d -n -o SIZE $DISK2))

СХЕМА РАЗДЕЛОВ:
$DISK1:
  - $D1P1: EFI boot (512MB)
  - $D1P2: /boot RAID (1GB) 
  - $D1P3: swap RAID (32GB)
  - $D1P4: / RAID (остальное)

$DISK2:
  - $D2P1: /boot RAID (1GB)
  - $D2P2: swap RAID (32GB)  
  - $D2P3: / RAID (остальное)

RAID МАССИВЫ:
md0 (/boot): $D1P2 + $D2P1
md1 (swap):  $D1P3 + $D2P2
md2 (/):     $D1P4 + $D2P3

UUID УСТРОЙСТВ:
EFI:      $(blkid -s UUID -o value $D1P1)
md0:      $(blkid -s UUID -o value /dev/md0)
md1:      $(blkid -s UUID -o value /dev/md1)
md2:      $(blkid -s UUID -o value /dev/md2)

СЛЕДУЮЩИЕ ШАГИ:
1. Смонтируйте новые разделы:
   sudo mount /dev/md2 /mnt
   sudo mkdir -p /mnt/boot/efi
   sudo mount /dev/md0 /mnt/boot
   sudo mount $D1P1 /mnt/boot/efi

2. Установите Ubuntu на RAID:
   sudo rsync -aAXv / /mnt/ --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found}

3. Настройте fstab:
   sudo cp /tmp/new-fstab /mnt/etc/fstab

4. Настройте загрузчик:
   sudo mount --bind /dev /mnt/dev
   sudo mount --bind /proc /mnt/proc
   sudo mount --bind /sys /mnt/sys
   sudo chroot /mnt update-initramfs -u -k all
   sudo chroot /mnt grub-install $DISK1
   sudo chroot /mnt grub-install $DISK2
   sudo chroot /mnt update-grub

Лог создания: $RAID_LOG
EOF

# Финальный отчет
clear
success "=== 🎉 RAID СИСТЕМА СОЗДАНА УСПЕШНО! ==="
echo ""
info "📊 СТАТУС RAID МАССИВОВ:"
cat /proc/mdstat
echo ""
info "📊 СОЗДАННЫЕ УСТРОЙСТВА:"
lsblk | grep -E "$(basename $DISK1)|$(basename $DISK2)|md[0-9]"
echo ""
info "📊 ФАЙЛОВЫЕ СИСТЕМЫ:"
lsblk -f | grep -E "md[0-9]|$(basename $D1P1)"
echo ""
success "✅ RAID массивы созданы и готовы к использованию"
success "✅ Файловые системы созданы"
success "✅ Конфигурация RAID сохранена"
echo ""
warning "📋 СЛЕДУЮЩИЕ ШАГИ:"
warning "1. Смонтируйте разделы в /mnt"
warning "2. Скопируйте текущую систему на RAID"
warning "3. Настройте fstab и загрузчик"
warning "4. Перезагрузитесь"
echo ""
info "📄 Подробные инструкции: /tmp/raid-setup-complete.txt"
info "📄 Новый fstab: /tmp/new-fstab"
info "📄 Лог операций: $RAID_LOG"
echo ""
success "🏆 RAID система готова к развертыванию!" 