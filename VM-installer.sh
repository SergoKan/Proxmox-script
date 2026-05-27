#!/usr/bin/env bash

set -Eeuo pipefail

# =====================================================
# COLORS & TRAP
# =====================================================
GREEN='\033[1;92m'
YELLOW='\033[33m'
RED='\033[01;31m'
BLUE='\033[36m'
NC='\033[m'
BOLD='\033[1m'

TEMP_DIR=""
SCRIPT_PATH="$(realpath "$0")"

cleanup_temp() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup_temp EXIT INT TERM

# =====================================================
# FUNCTIONS
# =====================================================
header() {
  clear
  cat <<"EOF"

██████╗ ██████╗  ██████╗ ██╗  ██╗███╗   ███╗ ██████╗ ██╗  ██╗
██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝████╗ ████║██╔═══██╗╚██╗██╔╝
██████╔╝██████╔╝██║   ██║ ╚███╔╝ ██╔████╔██║██║   ██║ ╚███╔╝ 
██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗ ██║╚██╔╝██║██║   ██║ ██╔██╗ 
██║     ██║  ██║╚██████╔╝██╔╝ ██╗██║ ╚═╝ ██║╚██████╔╝██╔╝ ██╗
╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝
 
EOF
  echo
}

msg_info()  { echo -e " ${YELLOW}.. $1...${NC}"; }
msg_ok()    { echo -e " ${GREEN}OK: $1${NC}"; }
msg_error() { echo -e " ${RED}ОШИБКА: $1${NC}"; }
msg_step()  { echo -e "${BLUE}${BOLD}--- $1 ---${NC}"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Запустите скрипт от root (через sudo)"
    exit 1
  fi
}

check_proxmox() {
  if ! command -v qm >/dev/null 2>&1; then
    msg_error "Скрипт предназначен только для Proxmox VE"
    exit 1
  fi
}

check_execution_method() {
  if [[ ! -f "$SCRIPT_PATH" || "$SCRIPT_PATH" == *"/bash"* ]]; then
    header
    msg_error "Запуск через 'curl | bash' невозможен."
    echo -e "Используйте:\n${GREEN}wget -qO f5go-openwrt-installer.sh ССЫЛКА && bash f5go-openwrt-installer.sh${NC}"
    exit 1
  fi
}

safe_self_destruct() {
  echo
  msg_info "Очистка временных файлов и автоудаление скрипта"
  if [[ -f "$SCRIPT_PATH" ]]; then
    (sleep 3 && rm -f "$SCRIPT_PATH") &
  fi
  msg_ok "Скрипт успешно завершен и удален."
  exit 0
}

# =====================================================
# OPENWRT INSTALL
# =====================================================
install_openwrt() {
  header
  msg_step "УСТАНОВКА OPENWRT"

  get_latest_openwrt_version() {
    local candidate=""
    local versions_page=""

    # 1) Предпочтительный путь: берем stable-версию с openwrt.org
    if versions_page=$(curl -fsSL https://openwrt.org 2>/dev/null); then
      candidate=$(echo "$versions_page" | sed -n 's/.*Current stable release - OpenWrt \([0-9.]\+\).*/\1/p' | head -n1)
      if [[ -n "$candidate" ]] && curl -fsSLI "https://downloads.openwrt.org/releases/$candidate/targets/x86/64/openwrt-$candidate-x86-64-generic-ext4-combined.img.gz" >/dev/null 2>&1; then
        echo "$candidate"
        return 0
      fi
    fi

    # 2) Резервный путь: парсим каталог releases и сортируем версии
    if versions_page=$(curl -fsSL https://downloads.openwrt.org/releases/ 2>/dev/null); then
      candidate=$(echo "$versions_page" | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/' | tr -d '"' | cut -d/ -f1 | sort -V | tail -n1)
      if [[ -n "$candidate" ]] && curl -fsSLI "https://downloads.openwrt.org/releases/$candidate/targets/x86/64/openwrt-$candidate-x86-64-generic-ext4-combined.img.gz" >/dev/null 2>&1; then
        echo "$candidate"
        return 0
      fi
    fi

    return 1
  }

  msg_info "Определение актуальной версии OpenWrt"
  if ! LATEST_VER=$(get_latest_openwrt_version); then
    msg_error "Не удалось автоматически определить актуальную стабильную версию OpenWrt."
    read -rp " Введите версию вручную (например 24.10.2): " USER_VER
    if [[ -z "${USER_VER:-}" ]]; then
      msg_error "Версия не указана. Установка прервана."
      exit 1
    fi
    LATEST_VER="$USER_VER"
  fi

  echo -e " Найдена актуальная версия: ${GREEN}$LATEST_VER${NC}"
  read -rp " Введите версию (или Enter для $LATEST_VER): " USER_VER
  SELECTED_VER=${USER_VER:-$LATEST_VER}

  BASE_URL="https://downloads.openwrt.org/releases/$SELECTED_VER/targets/x86/64"
  IMG_NAME="openwrt-$SELECTED_VER-x86-64-generic-ext4-combined.img.gz"

  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  msg_info "Загрузка образа и проверка SHA256"
  curl -fL# -o openwrt.img.gz "$BASE_URL/$IMG_NAME"
  curl -fsSL -o sha256sums "$BASE_URL/sha256sums"

  ACTUAL_HASH=$(grep "$IMG_NAME" sha256sums | awk '{print $1}')
  if [[ -z "$ACTUAL_HASH" ]]; then
    msg_error "Не удалось найти хэш для версии $SELECTED_VER в файле sha256sums!"
    exit 1
  fi

  if ! echo "$ACTUAL_HASH  openwrt.img.gz" | sha256sum -c - >/dev/null 2>&1; then
    msg_error "Ошибка проверки контрольной суммы (SHA256 mismatch)!"
    exit 1
  fi
  msg_ok "Образ загружен и успешно проверен"

  msg_info "Распаковка образа"
  zcat openwrt.img.gz > openwrt.img

  # === Создание VM ===
  NEXTID=$(pvesh get /cluster/nextid)
  read -rp " Введите VM ID [$NEXTID]: " VMID
  VMID=${VMID:-$NEXTID}

  STORAGE=$(pvesm status -content images | awk 'NR>1 && $1 !~ /^local$/ {print $1}' | head -n1)
  read -rp " Выберите Storage [$STORAGE]: " USER_STORAGE
  STORAGE=${USER_STORAGE:-$STORAGE}

  read -rp " Объем RAM (МБ) [512]: " VM_RAM
  VM_RAM=${VM_RAM:-512}
  read -rp " Объем диска (МБ) [512]: " VM_ROM
  VM_ROM=${VM_ROM:-512}

  msg_info "Создание VM $VMID"
  qm create "$VMID" \
    -name "OpenWRT" \
    -cores 1 \
    -memory "$VM_RAM" \
    -ostype l26 \
    -cpu host \
    -scsihw virtio-scsi-pci \
    -onboot 1 \
    -tablet 0

  msg_info "Настройка EFI-диска"
  pvesm alloc "$STORAGE" "$VMID" "vm-$VMID-disk-0" 4M >/dev/null 2>&1 || true
  qm set "$VMID" -efidisk0 "${STORAGE}:vm-$VMID-disk-0,efitype=4m,size=4M" >/dev/null 2>&1 || \
  qm set "$VMID" -efidisk0 "${STORAGE}:0,efitype=4m,size=4M" >/dev/null

  msg_info "Импорт диска в хранилище $STORAGE"
  qm importdisk "$VMID" openwrt.img "$STORAGE" --format raw >/dev/null
  sleep 2

  DISK_REF="$(pvesm list "$STORAGE" | grep "vm-$VMID-disk" | grep -v "disk-0" | awk '{print $1}' | tail -n1)"
  if [[ -z "$DISK_REF" ]]; then
    msg_error "Не удалось определить ссылку на импортированный диск!"
    exit 1
  fi

  qm set "$VMID" \
    -scsi0 "$DISK_REF" \
    -boot order=scsi0 \
    -bootdisk scsi0 >/dev/null

  msg_info "Изменение размера диска до ${VM_ROM}MB"
  qm disk resize "$VMID" scsi0 "${VM_ROM}M" >/dev/null

  header
  msg_ok "OpenWrt VM $VMID успешно создана!"

  safe_self_destruct
}

# =====================================================
# MIKROTIK CHR INSTALL
# =====================================================
install_mikrotik_chr() {
  header
  msg_step "УСТАНОВКА MIKROTIK CHR"

  # --- Получение списка версий по каналу ---
  get_chr_versions_for_channel() {
    local channel="$1"
    local json
    json=$(curl -fsSL "https://mikrotik.com/download/changelogs/$channel" 2>/dev/null) || return 1
    echo "$json" | grep -oE '"version"\s*:\s*"[0-9]+\.[0-9]+(\.[0-9]+)?"' \
      | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' \
      | sort -V | uniq
  }

  # Резервный способ: парсим HTML страницы загрузки
  get_chr_versions_fallback() {
    local channel="$1"
    local html
    html=$(curl -fsSL "https://mikrotik.com/download" 2>/dev/null) || return 1
    echo "$html" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' \
      | sort -V | uniq
  }

  # Проверка существования образа CHR для заданной версии
  check_chr_image_exists() {
    local ver="$1"
    curl -fsSLI "https://download.mikrotik.com/routeros/$ver/chr-$ver.img.zip" >/dev/null 2>&1
  }

  # Получить последнюю версию по каналу
  get_latest_chr_version() {
    local channel="$1"
    local candidate=""
    local versions=""

    versions=$(get_chr_versions_for_channel "$channel" 2>/dev/null)
    if [[ -z "$versions" ]]; then
      versions=$(get_chr_versions_fallback "$channel" 2>/dev/null)
    fi

    if [[ -n "$versions" ]]; then
      while IFS= read -r ver; do
        if check_chr_image_exists "$ver"; then
          candidate="$ver"
        fi
      done <<< "$(echo "$versions" | sort -V)"
      if [[ -n "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    fi

    return 1
  }

  # ── Выбор канала ──────────────────────────────────────────────────────────
  echo
  echo -e " Доступные каналы MikroTik:"
  echo -e "   ${GREEN}1)${NC} longTerm    — долгосрочная поддержка (рекомендуется)"
  echo -e "   ${GREEN}2)${NC} stable      — актуальный стабильный релиз"
  echo -e "   ${GREEN}3)${NC} testing     — кандидат в релизы (RC)"
  echo -e "   ${GREEN}4)${NC} development — разработческие сборки"
  echo
  read -rp " Выберите канал [1-4, по умолчанию 1 (longTerm)]: " CHANNEL_CHOICE

  case "${CHANNEL_CHOICE:-1}" in
    1|"longTerm"|"longterm")   CHANNEL="longTerm"   ;;
    2|"stable")                CHANNEL="stable"      ;;
    3|"testing")               CHANNEL="testing"     ;;
    4|"development")           CHANNEL="development" ;;
    *)
      msg_error "Неверный выбор канала. Используется longTerm."
      CHANNEL="longTerm"
      ;;
  esac

  echo -e " Выбран канал: ${GREEN}$CHANNEL${NC}"

  # ── Определение версии ────────────────────────────────────────────────────
  msg_info "Определение актуальной версии MikroTik CHR (канал: $CHANNEL)"

  if ! LATEST_VER=$(get_latest_chr_version "$CHANNEL"); then
    msg_error "Не удалось автоматически определить актуальную версию для канала '$CHANNEL'."
    read -rp " Введите версию вручную (например 7.21.4): " USER_VER
    if [[ -z "${USER_VER:-}" ]]; then
      msg_error "Версия не указана. Установка прервана."
      exit 1
    fi
    LATEST_VER="$USER_VER"
  fi

  echo -e " Найдена актуальная версия: ${GREEN}$LATEST_VER${NC}"
  read -rp " Введите версию (или Enter для $LATEST_VER): " USER_VER
  SELECTED_VER=${USER_VER:-$LATEST_VER}

  BASE_URL="https://download.mikrotik.com/routeros/$SELECTED_VER"
  IMG_ZIP_NAME="chr-$SELECTED_VER.img.zip"
  IMG_NAME="chr-$SELECTED_VER.img"

  # ── Загрузка образа ───────────────────────────────────────────────────────
  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  msg_info "Загрузка образа CHR $SELECTED_VER и проверка SHA256"

  if ! curl -fL# -o "$IMG_ZIP_NAME" "$BASE_URL/$IMG_ZIP_NAME"; then
    msg_error "Не удалось загрузить образ: $BASE_URL/$IMG_ZIP_NAME"
    exit 1
  fi

  HASH_FILE="sha256sums.txt"
  if curl -fsSL -o "$HASH_FILE" "$BASE_URL/sha256sums.txt" 2>/dev/null; then
    ACTUAL_HASH=$(grep "$IMG_ZIP_NAME" "$HASH_FILE" | awk '{print $1}')
    if [[ -n "$ACTUAL_HASH" ]]; then
      if ! echo "$ACTUAL_HASH  $IMG_ZIP_NAME" | sha256sum -c - >/dev/null 2>&1; then
        msg_error "Ошибка проверки контрольной суммы (SHA256 mismatch)!"
        exit 1
      fi
      msg_ok "SHA256 проверен успешно"
    else
      msg_info "Хэш для файла не найден в sha256sums.txt — проверка пропущена"
    fi
  else
    msg_info "Файл sha256sums.txt недоступен — проверка контрольной суммы пропущена"
  fi

  msg_info "Распаковка образа"
  unzip -q "$IMG_ZIP_NAME" -d .
  if [[ ! -f "$IMG_NAME" ]]; then
    IMG_NAME=$(find . -maxdepth 2 -name "*.img" | head -n1)
    if [[ -z "$IMG_NAME" ]]; then
      msg_error "Не удалось найти .img файл после распаковки архива!"
      exit 1
    fi
  fi
  msg_ok "Образ распакован: $IMG_NAME"

  # ── Создание VM ───────────────────────────────────────────────────────────
  NEXTID=$(pvesh get /cluster/nextid)
  read -rp " Введите VM ID [$NEXTID]: " VMID
  VMID=${VMID:-$NEXTID}

  STORAGE=$(pvesm status -content images | awk 'NR>1 && $1 !~ /^local$/ {print $1}' | head -n1)
  read -rp " Выберите Storage [$STORAGE]: " USER_STORAGE
  STORAGE=${USER_STORAGE:-$STORAGE}

  read -rp " Объем RAM (МБ) [256]: " VM_RAM
  VM_RAM=${VM_RAM:-256}
  read -rp " Объем диска (МБ) [512]: " VM_ROM
  VM_ROM=${VM_ROM:-512}

  msg_info "Создание VM $VMID (MikroTik CHR $SELECTED_VER)"
  qm create "$VMID" \
    -name "MikroTik-CHR-$SELECTED_VER" \
    -cores 1 \
    -memory "$VM_RAM" \
    -ostype l26 \
    -cpu host \
    -scsihw virtio-scsi-pci \
    -onboot 1 \
    -tablet 0

  msg_info "Настройка EFI-диска"
  pvesm alloc "$STORAGE" "$VMID" "vm-$VMID-disk-0" 4M >/dev/null 2>&1 || true
  qm set "$VMID" -efidisk0 "${STORAGE}:vm-$VMID-disk-0,efitype=4m,size=4M" >/dev/null 2>&1 || \
  qm set "$VMID" -efidisk0 "${STORAGE}:0,efitype=4m,size=4M" >/dev/null

  msg_info "Импорт диска CHR в хранилище $STORAGE"
  qm importdisk "$VMID" "$IMG_NAME" "$STORAGE" --format raw >/dev/null
  sleep 2

  DISK_REF="$(pvesm list "$STORAGE" | grep "vm-$VMID-disk" | grep -v "disk-0" | awk '{print $1}' | tail -n1)"
  if [[ -z "$DISK_REF" ]]; then
    msg_error "Не удалось определить ссылку на импортированный диск!"
    exit 1
  fi

  qm set "$VMID" \
    -scsi0 "$DISK_REF" \
    -boot order=scsi0 \
    -bootdisk scsi0 >/dev/null

  msg_info "Изменение размера диска до ${VM_ROM}MB"
  qm disk resize "$VMID" scsi0 "${VM_ROM}M" >/dev/null

  # ── Итог ──────────────────────────────────────────────────────────────────
  header
  msg_ok "MikroTik CHR $SELECTED_VER (канал: $CHANNEL) VM $VMID успешно создана!"

  safe_self_destruct
}

# =====================================================
# OPNSENSE INSTALL
# =====================================================
install_opnsense() {
  header
  msg_step "УСТАНОВКА OPNSENSE"

  # ── Получение актуальной версии с pkg.opnsense.org ──────────────────────
  # Структура каталога: https://pkg.opnsense.org/releases/
  # Точечные релизы вида 26.1.6/ имеют приоритет над базовыми 26.1/
  get_latest_opnsense_version() {
    local arch="$1"
    local releases_html
    releases_html=$(curl -fsSL "https://pkg.opnsense.org/releases/" 2>/dev/null) || return 1

    # Извлекаем все версии из href: и базовые (26.1) и точечные (26.1.6)
    local versions
    versions=$(echo "$releases_html" \
      | grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' \
      | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' \
      | sort -V | uniq)

    if [[ -z "$versions" ]]; then
      return 1
    fi

    # Берём самую новую, для которой реально существует img.bz2 образ
    local candidate=""
    local ver
    while IFS= read -r ver; do
      local url="https://pkg.opnsense.org/releases/$ver/OPNsense-$ver-vga-$arch.img.bz2"
      if curl -fsSLI "$url" >/dev/null 2>&1; then
        candidate="$ver"
      fi
    done <<< "$versions"

    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi

    return 1
  }

  # ── Выбор архитектуры ────────────────────────────────────────────────────
  echo
  echo -e " Доступные архитектуры OPNsense:"
  echo -e "   ${GREEN}1)${NC} amd64  — 64-bit x86 (рекомендуется, по умолчанию)"
  echo
  read -rp " Выберите архитектуру [1 / amd64, по умолчанию amd64]: " ARCH_CHOICE

  case "${ARCH_CHOICE:-1}" in
    1|"amd64") ARCH="amd64" ;;
    *)
      msg_error "Неверный выбор архитектуры. Используется amd64."
      ARCH="amd64"
      ;;
  esac

  echo -e " Выбрана архитектура: ${GREEN}$ARCH${NC}"

  # ── Выбор типа образа ────────────────────────────────────────────────────
  echo
  echo -e " Доступные типы образов OPNsense:"
  echo -e "   ${GREEN}1)${NC} vga    — USB-установщик с live-системой, VGA/UEFI (по умолчанию)"
  echo -e "   ${GREEN}2)${NC} dvd    — ISO-установщик с live-системой, VGA/UEFI"
  echo -e "   ${GREEN}3)${NC} serial — USB-установщик, серийная консоль 115200 + UEFI"
  echo -e "   ${GREEN}4)${NC} nano   — преустановленный образ для USB/SD/CF, MBR, 3G"
  echo
  read -rp " Выберите тип [1-4, по умолчанию 1 (vga)]: " TYPE_CHOICE

  case "${TYPE_CHOICE:-1}" in
    1|"vga")    IMG_TYPE="vga";    IMG_EXT="img.bz2" ;;
    2|"dvd")    IMG_TYPE="dvd";    IMG_EXT="iso.bz2" ;;
    3|"serial") IMG_TYPE="serial"; IMG_EXT="img.bz2" ;;
    4|"nano")   IMG_TYPE="nano";   IMG_EXT="img.bz2" ;;
    *)
      msg_error "Неверный выбор типа. Используется vga."
      IMG_TYPE="vga"
      IMG_EXT="img.bz2"
      ;;
  esac

  echo -e " Выбран тип образа: ${GREEN}$IMG_TYPE${NC}"

  # ── Определение версии ───────────────────────────────────────────────────
  msg_info "Определение актуальной версии OPNsense (arch: $ARCH)"

  if ! LATEST_VER=$(get_latest_opnsense_version "$ARCH"); then
    msg_error "Не удалось автоматически определить актуальную версию OPNsense."
    read -rp " Введите версию вручную (например 26.1.6): " USER_VER
    if [[ -z "${USER_VER:-}" ]]; then
      msg_error "Версия не указана. Установка прервана."
      exit 1
    fi
    LATEST_VER="$USER_VER"
  fi

  echo -e " Найдена актуальная версия: ${GREEN}$LATEST_VER${NC}"
  read -rp " Введите версию (или Enter для $LATEST_VER): " USER_VER
  SELECTED_VER=${USER_VER:-$LATEST_VER}

  BASE_URL="https://pkg.opnsense.org/releases/$SELECTED_VER"
  IMG_ARCHIVE="OPNsense-$SELECTED_VER-$IMG_TYPE-$ARCH.$IMG_EXT"
  # Имя файла после распаковки
  case "$IMG_EXT" in
    "img.bz2") IMG_UNPACKED="OPNsense-$SELECTED_VER-$IMG_TYPE-$ARCH.img" ;;
    "iso.bz2") IMG_UNPACKED="OPNsense-$SELECTED_VER-$IMG_TYPE-$ARCH.iso" ;;
  esac
  CHECKSUM_FILE="OPNsense-$SELECTED_VER-checksums-$ARCH.sha256"

  # ── Загрузка образа ──────────────────────────────────────────────────────
  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  msg_info "Загрузка образа OPNsense $SELECTED_VER ($IMG_TYPE/$ARCH)"

  if ! curl -fL# -o "$IMG_ARCHIVE" "$BASE_URL/$IMG_ARCHIVE"; then
    msg_error "Не удалось загрузить образ: $BASE_URL/$IMG_ARCHIVE"
    exit 1
  fi

  # ── Проверка SHA256 ──────────────────────────────────────────────────────
  msg_info "Загрузка и проверка контрольной суммы SHA256"

  if curl -fsSL "$CHECKSUM_FILE" "$BASE_URL/$CHECKSUM_FILE" 2>/dev/null; then
    ACTUAL_HASH=$(grep "$IMG_ARCHIVE" "$CHECKSUM_FILE" | awk '{print $1}')
    if [[ -n "$ACTUAL_HASH" ]]; then
      if ! echo "$ACTUAL_HASH  $IMG_ARCHIVE" | sha256sum -c - >/dev/null 2>&1; then
        msg_error "Ошибка проверки контрольной суммы (SHA256 mismatch)!"
        exit 1
      fi
      msg_ok "SHA256 проверен успешно"
    else
      msg_info "Хэш для файла не найден в checksums — проверка пропущена"
    fi
  else
    msg_info "Файл checksums недоступен — проверка контрольной суммы пропущена"
  fi

  # ── Распаковка образа ────────────────────────────────────────────────────
  msg_info "Распаковка образа (bzip2)"
  if ! bunzip2 -k "$IMG_ARCHIVE"; then
    msg_error "Ошибка распаковки архива $IMG_ARCHIVE!"
    exit 1
  fi

  if [[ ! -f "$IMG_UNPACKED" ]]; then
    # На случай нестандартного имени — ищем любой подходящий файл
    IMG_UNPACKED=$(find . -maxdepth 1 \( -name "*.img" -o -name "*.iso" \) | head -n1)
    if [[ -z "$IMG_UNPACKED" ]]; then
      msg_error "Не удалось найти распакованный образ!"
      exit 1
    fi
  fi
  msg_ok "Образ распакован: $IMG_UNPACKED"

  # ── Создание VM ──────────────────────────────────────────────────────────
  NEXTID=$(pvesh get /cluster/nextid)
  read -rp " Введите VM ID [$NEXTID]: " VMID
  VMID=${VMID:-$NEXTID}

  STORAGE=$(pvesm status -content images | awk 'NR>1 && $1 !~ /^local$/ {print $1}' | head -n1)
  read -rp " Выберите Storage [$STORAGE]: " USER_STORAGE
  STORAGE=${USER_STORAGE:-$STORAGE}

  read -rp " Объем RAM (МБ) [1024]: " VM_RAM
  VM_RAM=${VM_RAM:-1024}
  read -rp " Объем диска (МБ) [8192]: " VM_ROM
  VM_ROM=${VM_ROM:-8192}

  msg_info "Создание VM $VMID (OPNsense $SELECTED_VER)"
  qm create "$VMID" \
    -name "OPNsense-$SELECTED_VER" \
    -cores 2 \
    -memory "$VM_RAM" \
    -ostype l26 \
    -cpu host \
    -scsihw virtio-scsi-pci \
    -onboot 1 \
    -tablet 0

  msg_info "Настройка EFI-диска"
  pvesm alloc "$STORAGE" "$VMID" "vm-$VMID-disk-0" 4M >/dev/null 2>&1 || true
  qm set "$VMID" -efidisk0 "${STORAGE}:vm-$VMID-disk-0,efitype=4m,size=4M" >/dev/null 2>&1 || \
  qm set "$VMID" -efidisk0 "${STORAGE}:0,efitype=4m,size=4M" >/dev/null

  msg_info "Импорт диска OPNsense в хранилище $STORAGE"
  qm importdisk "$VMID" "$IMG_UNPACKED" "$STORAGE" --format raw >/dev/null
  sleep 2

  DISK_REF="$(pvesm list "$STORAGE" | grep "vm-$VMID-disk" | grep -v "disk-0" | awk '{print $1}' | tail -n1)"
  if [[ -z "$DISK_REF" ]]; then
    msg_error "Не удалось определить ссылку на импортированный диск!"
    exit 1
  fi

  qm set "$VMID" \
    -scsi0 "$DISK_REF" \
    -boot order=scsi0 \
    -bootdisk scsi0 >/dev/null

  msg_info "Изменение размера диска до ${VM_ROM}MB"
  qm disk resize "$VMID" scsi0 "${VM_ROM}M" >/dev/null

  # ── Итог ─────────────────────────────────────────────────────────────────
  header
  msg_ok "OPNsense $SELECTED_VER ($IMG_TYPE/$ARCH) VM $VMID успешно создана!"
  echo
  echo -e " Данные для входа по умолчанию:"
  echo -e "   Логин:    ${GREEN}root${NC}"
  echo -e "   Пароль:   ${GREEN}opnsense${NC}"
  echo -e "   Web GUI:  ${GREEN}https://192.168.1.1${NC} (LAN интерфейс)"

  safe_self_destruct
}

# =====================================================
# MAIN
# =====================================================
check_root
check_proxmox
check_execution_method

while true; do
  header
  echo " 1) Установить OpenWrt VM"
  echo " 2) Установить MikroTik CHR VM"
  echo " 3) Установить OPNsense VM"
  echo " 0) Выход"
  echo
  read -rp " Выберите действие: " OPT

  case "$OPT" in
    1) install_openwrt ;;
    2) install_mikrotik_chr ;;
    3) install_opnsense ;;
    0) exit 0 ;;
    *) echo " Неверный выбор." ;;
  esac
done