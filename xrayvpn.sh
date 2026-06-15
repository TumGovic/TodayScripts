#!/usr/bin/env bash
# xrayvpn.sh v1.1 (sing-box core)
# inbound: VLESS Reality или VLESS TLS на своём домене (TCP/443) -> outbound: direct
#
# ВАЖНО:
# - JSON sing-box генерируется только jq
# - state: /etc/xrayvpn (root-only)
# - config: /etc/sing-box/xrayvpn/config.json
# - systemd: xrayvpn.service

set -eEuo pipefail

########################################
# Константы / Пути
########################################
readonly SCRIPT_NAME="xrayvpn"
readonly SCRIPT_VERSION="1.1"

readonly STATE_DIR="/etc/xrayvpn"
readonly STATE_FILE="${STATE_DIR}/config.conf"
readonly CLIENTS_DB="${STATE_DIR}/clients.db"

readonly SB_BIN_DEFAULT="/usr/local/bin/sing-box"
readonly SB_CONFIG_ROOT="/etc/sing-box"
readonly SB_CONFIG_DIR="${SB_CONFIG_ROOT}/xrayvpn"
readonly SB_CONFIG_FILE="${SB_CONFIG_DIR}/config.json"

readonly SERVICE_NAME="xrayvpn"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

readonly SERVICE_USER="xrayvpn"
readonly SERVICE_GROUP="xrayvpn"

readonly REQUIRED_DEPS=(curl jq)
readonly OPTIONAL_DEPS=(qrencode)

readonly FIXED_VLESS_PORT="443"
readonly FIXED_FLOW="xtls-rprx-vision"

########################################
# Цвета
########################################
if [[ -t 1 ]]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly BLUE='\033[0;34m'
  readonly NC='\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

########################################
# Логирование
########################################
log_info(){ echo -e "${BLUE}[ИНФО]${NC} ${1:-}"; }
log_success(){ echo -e "${GREEN}[OK]${NC} ${1:-}"; }
log_warning(){ echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} ${1:-}"; }
log_error(){ echo -e "${RED}[ОШИБКА]${NC} ${1:-}" >&2; }
die(){ log_error "${1:-}"; exit "${2:-1}"; }

########################################
# Трап ошибок
########################################
on_err() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-}
  local cmd=${BASH_COMMAND:-}
  log_error "Сбой (код=${exit_code}) на строке ${line_no}: ${cmd}"
  exit "$exit_code"
}
trap on_err ERR

########################################
# Утилиты
########################################
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

check_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Нужно запустить от root (например: sudo ${SCRIPT_NAME} install)"
}

trim_ws() {
  local s="${1:-}"
  s="$(echo "$s" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  printf '%s' "$s"
}

########################################
# Проверка порта (без ss/netstat/lsof)
########################################
# Возвращает 0 если порт LISTEN, иначе 1.
# Проверяем /proc/net/tcp и /proc/net/tcp6 (state 0A = LISTEN)
port_is_listening() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [[ -r /proc/net/tcp ]] || return 1

  local hex
  printf -v hex '%04X' "$port"

  # /proc/net/tcp: local_address = "00000000:01BB" state = "0A"
  awk -v p=":${hex}" 'NR>1 { if (index($2,p)>0 && $4=="0A") {found=1; exit} } END{exit !found}' /proc/net/tcp 2>/dev/null \
    && return 0

  if [[ -r /proc/net/tcp6 ]]; then
    awk -v p=":${hex}" 'NR>1 { if (index($2,p)>0 && $4=="0A") {found=1; exit} } END{exit !found}' /proc/net/tcp6 2>/dev/null \
      && return 0
  fi

  return 1
}

ensure_port_443_free_or_exit() {
  # Если сервис уже наш и активен — остановим, чтобы переустановка не падала.
  if port_is_listening 443; then
    if have_cmd systemctl && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      log_warning "Порт 443 занят сервисом ${SERVICE_NAME}. Останавливаю для переустановки..."
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
  fi

  if port_is_listening 443; then
    die "Порт 443 уже занят (LISTEN). Освободи 443 и запусти снова."
  fi
}

########################################
# Интерактивный ввод (с дефолтом)
########################################
prompt_default() {
  local prompt="${1:-}" default="${2:-}" __var="${3:-}"
  [[ -n "$__var" ]] || die "prompt_default: не задано имя переменной"

  local ans=""
  if [[ -n "$default" ]]; then
    echo -n "${prompt} [${default}]: "
  else
    echo -n "${prompt}: "
  fi
  IFS= read -r ans || die "Ввод прерван"
  ans="$(trim_ws "$ans")"
  if [[ -z "$ans" ]]; then
    ans="$default"
  fi
  printf -v "$__var" '%s' "$ans"
}

prompt_required() {
  local prompt="${1:-}" default="${2:-}" __var="${3:-}" hint="${4:-}"
  while true; do
    [[ -n "$hint" ]] && echo "$hint"
    prompt_default "$prompt" "$default" "$__var"
    local val="${!__var:-}"
    val="$(trim_ws "$val")"
    printf -v "$__var" '%s' "$val"
    [[ -n "$val" ]] && return 0
    log_warning "Поле обязательно. Нажми Enter только если подсказка заполнена."
  done
}

########################################
# URL encode (для VLESS URI)
########################################
url_encode() {
  local s="${1:-}"
  local out="" i c hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

########################################
# Пакеты/зависимости
########################################
detect_pkg_manager() {
  if have_cmd apt-get; then echo apt
  elif have_cmd dnf; then echo dnf
  elif have_cmd yum; then echo yum
  elif have_cmd pacman; then echo pacman
  elif have_cmd apk; then echo apk
  else echo unknown
  fi
}

install_packages() {
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) dnf install -y "$@";;
    yum) yum install -y "$@";;
    pacman) pacman -Sy --noconfirm "$@";;
    apk) apk add --no-cache "$@";;
    *) die "Неизвестный пакетный менеджер. Установи вручную: $*";;
  esac
}

check_dependencies() {
  local missing=()
  for d in "${REQUIRED_DEPS[@]}"; do
    have_cmd "$d" || missing+=("$d")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Ставлю зависимости: ${missing[*]}"
    install_packages "${missing[@]}" || die "Не удалось установить зависимости: ${missing[*]}"
  fi

  local opt_missing=()
  for d in "${OPTIONAL_DEPS[@]}"; do
    have_cmd "$d" || opt_missing+=("$d")
  done
  if [[ ${#opt_missing[@]} -gt 0 ]]; then
    log_warning "Опционально можно установить: ${opt_missing[*]} (для QR-кодов)"
  fi

  have_cmd jq || die "jq обязателен, но не найден и/или не удалось установить"
}

########################################
# Пользователь/группа/директории
########################################
ensure_user_group() {
  if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    log_info "Создаю группу: ${SERVICE_GROUP}"
    groupadd --system "$SERVICE_GROUP"
  fi
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log_info "Создаю пользователя: ${SERVICE_USER}"
    useradd --system --gid "$SERVICE_GROUP" --home-dir /var/lib/"$SERVICE_USER" --create-home \
      --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
}

ensure_dirs() {
  install -d -m 700 -o root -g root "$STATE_DIR"
  install -d -m 750 -o root -g "$SERVICE_GROUP" "$SB_CONFIG_ROOT"
  install -d -m 750 -o root -g "$SERVICE_GROUP" "$SB_CONFIG_DIR"
}

########################################
# State
########################################
write_state_kv() {
  local tmp
  tmp="$(mktemp)"
  umask 077
  {
    printf 'STATE_SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
    printf 'SB_BIN=%q\n' "${SB_BIN:-$SB_BIN_DEFAULT}"
    printf 'SERVER_ADDR=%q\n' "${SERVER_ADDR:-}"
    printf 'VLESS_PORT=%q\n' "${VLESS_PORT:-$FIXED_VLESS_PORT}"
    printf 'TLS_MODE=%q\n' "${TLS_MODE:-reality}"
    printf 'MASK_DOMAIN=%q\n' "${MASK_DOMAIN:-}"
    printf 'ACME_EMAIL=%q\n' "${ACME_EMAIL:-}"
    printf 'CERT_PATH=%q\n' "${CERT_PATH:-}"
    printf 'KEY_PATH=%q\n' "${KEY_PATH:-}"
    printf 'REALITY_SNI=%q\n' "${REALITY_SNI:-}"
    printf 'REALITY_DEST=%q\n' "${REALITY_DEST:-}"
    printf 'PRIVATE_KEY=%q\n' "${PRIVATE_KEY:-}"
    printf 'PUBLIC_KEY=%q\n' "${PUBLIC_KEY:-}"
    printf 'SHORT_ID=%q\n' "${SHORT_ID:-}"
    printf 'FLOW=%q\n' "${FLOW:-$FIXED_FLOW}"
    printf 'FINGERPRINT=%q\n' "${FINGERPRINT:-}"
  } > "$tmp"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  chown root:root "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "Не установлен. Сначала: ${SCRIPT_NAME} install"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  : "${SB_BIN:=${SB_BIN_DEFAULT}}"
}

########################################
# sing-box install/upgrade
########################################
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    i386|i686) echo "386" ;;
    *) die "Неизвестная архитектура: $arch" ;;
  esac
}

install_singbox() {
  local sb_bin="${SB_BIN:-$SB_BIN_DEFAULT}"

  if [[ -x "$sb_bin" ]]; then
    log_info "sing-box уже установлен: $sb_bin"
    return 0
  fi

  log_info "Устанавливаю sing-box (GitHub Releases) ..."

  local arch os version tag asset url tmpdir
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  [[ "$os" == "linux" ]] || die "Поддерживается только Linux (обнаружено: $os)"
  arch="$(detect_arch)"

  tag="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')"
  [[ -n "$tag" && "$tag" != "null" ]] || die "Не удалось получить версию sing-box из GitHub API"
  version="${tag#v}"

  asset="sing-box-${version}-${os}-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset}"

  tmpdir="$(mktemp -d)"
  (
    cd "$tmpdir"
    curl -fL --retry 3 --retry-delay 1 -o "$asset" "$url"
    tar -xzf "$asset"
    local extracted
    extracted="$(find . -type f -name sing-box -perm -111 | head -n1)"
    [[ -n "$extracted" ]] || die "Не нашёл бинарник sing-box в архиве"
    install -m 0755 "$extracted" "$sb_bin"
  )
  rm -rf "$tmpdir"

  log_success "sing-box установлен: $sb_bin"
}

########################################
# Генерация ключей/UUID
########################################
generate_uuid() {
  if have_cmd "${SB_BIN:-$SB_BIN_DEFAULT}" && "${SB_BIN:-$SB_BIN_DEFAULT}" generate uuid >/dev/null 2>&1; then
    "${SB_BIN:-$SB_BIN_DEFAULT}" generate uuid
    return 0
  fi
  cat /proc/sys/kernel/random/uuid
}

generate_short_id() {
  od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

parse_dest() {
  local d
  d="$(trim_ws "${1:-}")"
  if [[ "$d" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$d" =~ ^([^:]+):([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

normalize_tls_mode() {
  local m
  m="$(trim_ws "${1:-}")"
  case "$m" in
    reality|REALITY) echo "reality" ;;
    domain|tls|TLS|own-domain|own_domain|cert|certificate) echo "domain" ;;
    *) return 1 ;;
  esac
}

is_domain_name() {
  local d="${1:-}"
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

get_public_ipv4() { curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true; }
get_public_ipv6() { curl -6 -fsSL --max-time 5 https://api64.ipify.org 2>/dev/null || true; }

resolve_domain_ips() {
  local domain="${1:-}"
  getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true
}

ip_in_list() {
  local needle="${1:-}"; shift || true
  local ip
  for ip in "$@"; do
    [[ "$ip" == "$needle" ]] && return 0
  done
  return 1
}

check_mask_domain_dns() {
  local domain="${1:-}" server_addr="${2:-}" strict="${3:-false}"
  is_domain_name "$domain" || die "Домен маскировки выглядит некорректно: $domain"

  local pub4 pub6 resolved=()
  pub4="$(get_public_ipv4)"
  pub6="$(get_public_ipv6)"
  mapfile -t resolved < <(resolve_domain_ips "$domain")

  if [[ ${#resolved[@]} -eq 0 ]]; then
    die "DNS не резолвит $domain. Создай A/AAAA запись на IP сервера и дождись обновления DNS."
  fi

  log_info "DNS $domain -> ${resolved[*]}"
  [[ -n "$pub4" ]] && log_info "Публичный IPv4 сервера: $pub4"
  [[ -n "$pub6" ]] && log_info "Публичный IPv6 сервера: $pub6"

  local ok="false"
  [[ -n "$server_addr" ]] && ip_in_list "$server_addr" "${resolved[@]}" && ok="true"
  [[ -n "$pub4" ]] && ip_in_list "$pub4" "${resolved[@]}" && ok="true"
  [[ -n "$pub6" ]] && ip_in_list "$pub6" "${resolved[@]}" && ok="true"

  if [[ "$ok" != "true" ]]; then
    local msg="DNS $domain пока не указывает на этот сервер. Нужна A-запись на IPv4 сервера и/или AAAA на IPv6."
    if [[ "$strict" == "true" ]]; then
      die "$msg"
    fi
    log_warning "$msg"
    log_warning "Если DNS только что изменён — подожди TTL и перезапусти install."
  else
    log_success "DNS выглядит нормально: домен указывает на сервер."
  fi
}

ensure_port_80_free_or_exit() {
  if port_is_listening 80; then
    die "Порт 80 уже занят. Для Let's Encrypt HTTP-01 он должен быть свободен на время выпуска сертификата."
  fi
}

install_certbot_if_needed() {
  if have_cmd certbot; then
    return 0
  fi
  log_info "Ставлю certbot для выпуска Let's Encrypt сертификата..."
  install_packages certbot || die "Не удалось установить certbot. Установи certbot вручную или используй --cert-path/--key-path."
}

ensure_domain_certificate() {
  local domain="${1:-}" email="${2:-}" cert_path="${3:-}" key_path="${4:-}"
  if [[ -n "$cert_path" || -n "$key_path" ]]; then
    [[ -f "$cert_path" ]] || die "Файл сертификата не найден: $cert_path"
    [[ -f "$key_path" ]] || die "Файл ключа не найден: $key_path"
    CERT_PATH="$cert_path"
    KEY_PATH="$key_path"
    log_success "Использую заданные сертификаты: $CERT_PATH / $KEY_PATH"
    return 0
  fi

  install_certbot_if_needed

  CERT_PATH="/etc/letsencrypt/live/${domain}/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/${domain}/privkey.pem"

  if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
    log_success "Сертификат уже есть: $CERT_PATH"
  else
    ensure_port_80_free_or_exit
    local email_args=(--register-unsafely-without-email)
    if [[ -n "$email" ]]; then
      email_args=(--email "$email")
    fi
    log_info "Выпускаю сертификат Let's Encrypt для $domain через HTTP-01 (порт 80)..."
    certbot certonly --standalone --non-interactive --agree-tos "${email_args[@]}" -d "$domain"
    [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || die "certbot завершился, но сертификат не найден: $CERT_PATH"
    log_success "Сертификат выпущен: $CERT_PATH"
  fi

  chgrp -R "$SERVICE_GROUP" /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
  chmod 750 /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
  find /etc/letsencrypt/live /etc/letsencrypt/archive -type d -exec chmod 750 {} + 2>/dev/null || true
  find /etc/letsencrypt/live /etc/letsencrypt/archive -type f -name 'privkey*.pem' -exec chgrp "$SERVICE_GROUP" {} + -exec chmod 640 {} + 2>/dev/null || true
  find /etc/letsencrypt/live /etc/letsencrypt/archive -type f -name 'fullchain*.pem' -exec chgrp "$SERVICE_GROUP" {} + -exec chmod 640 {} + 2>/dev/null || true

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy 2>/dev/null || true
  cat > /etc/letsencrypt/renewal-hooks/deploy/xrayvpn-reload.sh <<EOF
#!/usr/bin/env bash
systemctl reload ${SERVICE_NAME} >/dev/null 2>&1 || systemctl restart ${SERVICE_NAME} >/dev/null 2>&1 || true
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/xrayvpn-reload.sh
}

generate_reality_keypair() {
  local sb="${SB_BIN:-$SB_BIN_DEFAULT}"
  [[ -x "$sb" ]] || die "sing-box не найден: $sb"

  local out priv pub
  out="$("$sb" generate reality-keypair 2>/dev/null)" || die "Не удалось: sing-box generate reality-keypair"

  priv="$(echo "$out" | awk -F': ' '/Private(Key)?/ {print $2; exit}')"
  pub="$(echo "$out" | awk -F': ' '/Public(Key)?/ {print $2; exit}')"
  [[ -n "$priv" && -n "$pub" ]] || die "Не удалось распарсить Reality keypair"
  echo "$priv|$pub"
}

########################################
# sing-box config (jq only)
########################################
build_users_json_from_db() {
  [[ -f "$CLIENTS_DB" ]] || { echo '[]'; return 0; }
  load_state >/dev/null 2>&1 || true

  local flow="${FLOW:-$FIXED_FLOW}"
  jq -c -R -s --arg flow "$flow" '
    [ split("\n")[]
      | select(length>0)
      | split(";")
      | select(length>=2 and (.[0]|length)>0 and (.[1]|length)>0)
      | ({name: .[0], uuid: .[1], flow: ($flow|tostring)})
    ]
  ' "$CLIENTS_DB"
}

build_tls_inbound_reality_json() {
  local dest_host="${1:-}" dest_port="${2:-}" priv="${3:-}" sid="${4:-}" server_name="${5:-}"
  jq -c -n \
    --arg dest_host "$dest_host" \
    --argjson dest_port "$dest_port" \
    --arg priv "$priv" \
    --arg sid "$sid" \
    --arg sni "$server_name" '
    {
      enabled: true
    }
    + (if ($sni|length)>0 then {server_name: $sni} else {} end)
    + {
      reality: {
        enabled: true,
        handshake: { server: $dest_host, server_port: $dest_port },
        private_key: $priv,
        short_id: $sid
      }
    }
  '
}

build_tls_inbound_domain_json() {
  local domain="${1:-}" cert_path="${2:-}" key_path="${3:-}"
  jq -c -n \
    --arg domain "$domain" \
    --arg cert "$cert_path" \
    --arg key "$key_path" '
    {
      enabled: true,
      server_name: $domain,
      certificate_path: $cert,
      key_path: $key
    }
  '
}

build_inbound_json() {
  local users_json="$1"

  local dest_host="" dest_port=""
  if [[ "${TLS_MODE:-reality}" == "reality" ]]; then
    IFS='|' read -r dest_host dest_port <<< "$(parse_dest "${REALITY_DEST:-}" || true)"
    [[ -n "${dest_host:-}" && -n "${dest_port:-}" ]] || die "Некорректный REALITY_DEST: ${REALITY_DEST:-}"
  fi

  local tls_json
  if [[ "${TLS_MODE:-reality}" == "reality" ]]; then
    tls_json="$(build_tls_inbound_reality_json "$dest_host" "$dest_port" "${PRIVATE_KEY:-}" "${SHORT_ID:-}" "${REALITY_SNI:-}")"
  else
    tls_json="$(build_tls_inbound_domain_json "${MASK_DOMAIN:-}" "${CERT_PATH:-}" "${KEY_PATH:-}")"
  fi

  jq -c -n \
    --arg listen "0.0.0.0" \
    --argjson port "${VLESS_PORT:-$FIXED_VLESS_PORT}" \
    --argjson users "$users_json" \
    --argjson tls "$tls_json" '
    {
      type: "vless",
      tag: "vless-in",
      listen: $listen,
      listen_port: $port,
      users: $users,
      tls: $tls
    }
  '
}

build_outbounds_json() {
  jq -c -n '
    [
      {type:"direct", tag:"direct"},
      {type:"block", tag:"block"}
    ]
  '
}

build_route_json() {
  jq -c -n '
    {
      rules: [
        {
          inbound: ["vless-in"],
          action: "sniff",
          sniffer: ["http","tls","quic"]
        },
        {
          inbound: ["vless-in"],
          action: "route",
          outbound: "direct"
        }
      ],
      final: "direct"
    }
  '
}

build_log_json() {
  jq -c -n '{ level: "warn", timestamp: true }'
}

render_singbox_config() {
  load_state

  [[ "${VLESS_PORT:-}" == "$FIXED_VLESS_PORT" ]] || die "VLESS_PORT должен быть ${FIXED_VLESS_PORT}"
  TLS_MODE="$(normalize_tls_mode "${TLS_MODE:-reality}" || true)"
  [[ -n "$TLS_MODE" ]] || die "TLS_MODE должен быть reality или domain"
  if [[ "$TLS_MODE" == "reality" ]]; then
    [[ -n "${REALITY_DEST:-}" ]] || die "REALITY_DEST не задан"
    [[ -n "${PRIVATE_KEY:-}" ]] || die "PRIVATE_KEY не задан"
    [[ -n "${SHORT_ID:-}" ]] || die "SHORT_ID не задан"
  else
    [[ -n "${MASK_DOMAIN:-}" ]] || die "MASK_DOMAIN не задан"
    [[ -n "${CERT_PATH:-}" ]] || die "CERT_PATH не задан"
    [[ -n "${KEY_PATH:-}" ]] || die "KEY_PATH не задан"
  fi

  local users_json inbound_json inbounds_json outbounds_json route_json log_json
  users_json="$(build_users_json_from_db)"
  inbound_json="$(build_inbound_json "$users_json")"
  inbounds_json="$(jq -c -n --argjson inbound "$inbound_json" '[ $inbound ]')"
  outbounds_json="$(build_outbounds_json)"
  route_json="$(build_route_json)"
  log_json="$(build_log_json)"

  local tmp prev
  tmp="$(mktemp)"
  prev=""
  if [[ -f "$SB_CONFIG_FILE" ]]; then
    prev="${SB_CONFIG_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "$SB_CONFIG_FILE" "$prev"
  fi

  jq -n \
    --argjson log "$log_json" \
    --argjson inbounds "$inbounds_json" \
    --argjson outbounds "$outbounds_json" \
    --argjson route "$route_json" '
    {
      log: $log,
      inbounds: $inbounds,
      outbounds: $outbounds,
      route: $route
    }
  ' > "$tmp"

  local check_out=""
  if check_out="$("${SB_BIN:-$SB_BIN_DEFAULT}" check -c "$tmp" 2>&1)"; then
    :
  else
    log_error "sing-box: конфиг не прошёл проверку: ${SB_BIN:-$SB_BIN_DEFAULT} check -c ${tmp}"
    log_error "Вывод sing-box check:"
    echo "$check_out" >&2
    log_error "Полный конфиг (для диагностики):"
    cat "$tmp" >&2
    if [[ -n "$prev" ]]; then
      log_warning "Откат на бэкап: $prev"
      cp -a "$prev" "$SB_CONFIG_FILE" || true
    fi
    rm -f "$tmp"
    die "Остановка: некорректный JSON конфиг"
  fi

  mv "$tmp" "$SB_CONFIG_FILE"
  chown root:"$SERVICE_GROUP" "$SB_CONFIG_FILE"
  chmod 640 "$SB_CONFIG_FILE"

  log_success "Конфиг sing-box обновлён: $SB_CONFIG_FILE"
}

########################################
# systemd управление сервисом
########################################
ensure_systemd() {
  have_cmd systemctl || die "systemd (systemctl) не найден"
}

install_service_unit() {
  ensure_systemd
  ensure_user_group
  ensure_dirs

  local sb="${SB_BIN:-$SB_BIN_DEFAULT}"
  [[ -x "$sb" ]] || die "sing-box binary не найден/не исполняемый: $sb"
  [[ -f "$SB_CONFIG_FILE" ]] || die "config.json не найден: $SB_CONFIG_FILE (сначала сгенерируй конфиг)"

  local marker="XrayVPN (sing-box)"
  local need_write=1
  if [[ -f "$SERVICE_FILE" ]]; then
    if grep -q "$marker" "$SERVICE_FILE" 2>/dev/null; then
      need_write=0
    else
      log_warning "Существующий ${SERVICE_FILE} не принадлежит скрипту. Перезапишу."
      need_write=1
    fi
  fi

  if (( need_write == 1 )); then
    log_info "Пишу systemd unit: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${marker}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

ExecStart=${sb} run -c ${SB_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID

StandardOutput=null
StandardError=null

Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

StateDirectory=${SERVICE_NAME}
LogsDirectory=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

service_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME"
}

service_reload() {
  ensure_systemd
  if systemctl reload "$SERVICE_NAME" >/dev/null 2>&1; then
    log_success "Сервис перезагружен (reload): $SERVICE_NAME"
    return 0
  fi

  log_warning "Reload не сработал. Делаю start/restart."
  if service_is_active; then
    systemctl restart "$SERVICE_NAME"
    log_success "Сервис перезапущен (restart): $SERVICE_NAME"
  else
    systemctl start "$SERVICE_NAME"
    log_success "Сервис запущен (start): $SERVICE_NAME"
  fi
}

service_status() {
  ensure_systemd
  systemctl --no-pager status "$SERVICE_NAME" || true
}

########################################
# Клиенты
########################################
client_exists() {
  local name="$1"
  [[ -f "$CLIENTS_DB" ]] || return 1
  awk -F';' -v n="$name" '$1==n{found=1; exit} END{exit !found}' "$CLIENTS_DB"
}

get_client_uuid() {
  local name="$1"
  [[ -f "$CLIENTS_DB" ]] || return 1
  awk -F';' -v n="$name" '$1==n{print $2; exit}' "$CLIENTS_DB"
}

add_client() {
  local client_name="$1"
  client_name="$(trim_ws "$client_name")"
  [[ -n "$client_name" ]] || die "Имя клиента пустое"
  [[ "$client_name" != *";"* ]] || die "Имя не должно содержать ';'"

  if client_exists "$client_name"; then
    die "Клиент '$client_name' уже существует"
  fi

  local uuid
  uuid="$(generate_uuid)"

  echo "${client_name};${uuid}" >> "$CLIENTS_DB"
  chmod 600 "$CLIENTS_DB"
  chown root:root "$CLIENTS_DB"

  log_success "Клиент добавлен: $client_name"
}

remove_client() {
  local client_name="$1"
  client_name="$(trim_ws "$client_name")"
  [[ -n "$client_name" ]] || die "Имя клиента пустое"
  client_exists "$client_name" || die "Клиент '$client_name' не найден"

  local tmp
  tmp="$(mktemp)"
  awk -F';' -v n="$client_name" '$1!=n{print $0}' "$CLIENTS_DB" > "$tmp"
  mv "$tmp" "$CLIENTS_DB"
  chmod 600 "$CLIENTS_DB"
  chown root:root "$CLIENTS_DB"

  log_success "Клиент удалён: $client_name"
}

generate_vless_url() {
  local client_name="$1" uuid="$2"
  load_state

  local tag="XrayVPN-$client_name"

  local server="$SERVER_ADDR"
  if [[ "$server" == *:* && "$server" != *.* ]]; then
    server="[$server]"
  fi

  local sni_enc fp_enc flow_enc pbk_enc sid_enc security
  fp_enc="$(url_encode "${FINGERPRINT:-chrome}")"
  flow_enc="$(url_encode "${FLOW:-$FIXED_FLOW}")"

  if [[ "${TLS_MODE:-reality}" == "domain" ]]; then
    security="tls"
    sni_enc="$(url_encode "${MASK_DOMAIN:-$SERVER_ADDR}")"
    local url="vless://${uuid}@${server}:${VLESS_PORT}?encryption=none&security=${security}&sni=${sni_enc}&fp=${fp_enc}&type=tcp&headerType=none&flow=${flow_enc}#$(url_encode "$tag")"
    echo "$url"
  else
    security="reality"
    sni_enc="$(url_encode "$REALITY_SNI")"
    pbk_enc="$(url_encode "$PUBLIC_KEY")"
    sid_enc="$(url_encode "$SHORT_ID")"
    local url="vless://${uuid}@${server}:${VLESS_PORT}?encryption=none&security=${security}&sni=${sni_enc}&fp=${fp_enc}&pbk=${pbk_enc}&sid=${sid_enc}&type=tcp&headerType=none&flow=${flow_enc}#$(url_encode "$tag")"
    echo "$url"
  fi
}

show_client_connection() {
  local client_name="$1"
  local uuid
  uuid="$(get_client_uuid "$client_name")"
  [[ -n "$uuid" ]] || die "Клиент '$client_name' не найден"

  local vless_url
  vless_url="$(generate_vless_url "$client_name" "$uuid")"

  echo
  echo "Клиент: $client_name"
  echo "UUID:   $uuid"
  echo "Режим:  ${TLS_MODE:-reality}"
  [[ "${TLS_MODE:-reality}" == "domain" ]] && echo "Домен:  ${MASK_DOMAIN:-}"
  echo
  echo "VLESS URI:"
  echo "$vless_url"
  echo

  if have_cmd qrencode; then
    echo "QR (для мобильных клиентов):"
    qrencode -t ANSIUTF8 "$vless_url" || true
    echo
  else
    log_warning "qrencode не установлен — QR не показываю"
  fi
}

list_clients() {
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"

  echo "┌─────┬──────────────────────────────────────┬──────────────────────────────────────┐"
  echo "│  №  │               Имя клиента            │                 UUID                 │"
  echo "├─────┼──────────────────────────────────────┼──────────────────────────────────────┤"
  local i=1
  while IFS=';' read -r n u; do
    [[ -z "${n:-}" ]] && continue
    printf "│ %3d │ %-36s │ %-36s │\n" "$i" "$n" "$u"
    i=$((i+1))
  done < "$CLIENTS_DB"
  echo "└─────┴──────────────────────────────────────┴──────────────────────────────────────┘"
}

########################################
# Команды
########################################
show_help() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} (sing-box core)

Команды:
  install        Установка/настройка VPN (VLESS Reality или VLESS TLS на своём домене, TCP/443 -> direct)
  add            Добавить клиента
  remove         Удалить клиента
  list           Список клиентов
  show [name]    Показать подключение клиента (URI + QR)
  status         Статус сервиса ${SERVICE_NAME}
  uninstall      Удалить сервис и конфиги xrayvpn (sing-box бинарник не трогаем)
  help           Эта справка

Параметры (install):
  --non-interactive|--yes|-y
  --server-addr <ip|domain>
  --tls-mode <reality|domain> (reality = старый режим, domain = свой домен + сертификат)
  --mask-domain <domain>      домен для режима domain; A/AAAA должен указывать на сервер
  --acme-email <email>        email для Let's Encrypt (опционально)
  --cert-path <path>          свой fullchain.pem вместо certbot
  --key-path <path>           свой privkey.pem вместо certbot
  --reality-sni <sni>
  --reality-dest <host:port>
  --fingerprint <fp>          (по умолчанию: chrome)
  --client-name <name>        (по умолчанию: user1)
  --reset-keys                (сгенерировать новый Reality keypair + short_id)

Переменные окружения (install):
  XRAYVPN_SERVER_ADDR
  XRAYVPN_TLS_MODE
  XRAYVPN_MASK_DOMAIN
  XRAYVPN_ACME_EMAIL
  XRAYVPN_CERT_PATH
  XRAYVPN_KEY_PATH
  XRAYVPN_REALITY_SNI
  XRAYVPN_REALITY_DEST
  XRAYVPN_FINGERPRINT
  XRAYVPN_CLIENT_NAME

EOF
}

cmd_install() {
  check_dependencies
  ensure_systemd
  ensure_user_group
  ensure_dirs

  # Всегда TCP/443. Если 443 занят — выходим.
  ensure_port_443_free_or_exit

  local non_interactive="false"
  local reset_keys="false"

  local server_addr="${XRAYVPN_SERVER_ADDR:-}"
  local tls_mode="${XRAYVPN_TLS_MODE:-reality}"
  local mask_domain="${XRAYVPN_MASK_DOMAIN:-}"
  local acme_email="${XRAYVPN_ACME_EMAIL:-}"
  local cert_path="${XRAYVPN_CERT_PATH:-}"
  local key_path="${XRAYVPN_KEY_PATH:-}"
  local reality_sni="${XRAYVPN_REALITY_SNI:-}"
  local reality_dest="${XRAYVPN_REALITY_DEST:-}"
  local fp="${XRAYVPN_FINGERPRINT:-chrome}"
  local client_name="${XRAYVPN_CLIENT_NAME:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive|--yes|-y) non_interactive="true"; shift ;;
      --reset-keys) reset_keys="true"; shift ;;
      --server-addr) server_addr="${2:-}"; shift 2 ;;
      --tls-mode) tls_mode="${2:-}"; shift 2 ;;
      --mask-domain) mask_domain="${2:-}"; shift 2 ;;
      --acme-email) acme_email="${2:-}"; shift 2 ;;
      --cert-path) cert_path="${2:-}"; shift 2 ;;
      --key-path) key_path="${2:-}"; shift 2 ;;
      --reality-sni) reality_sni="${2:-}"; shift 2 ;;
      --reality-dest) reality_dest="${2:-}"; shift 2 ;;
      --fingerprint) fp="${2:-}"; shift 2 ;;
      --client-name) client_name="${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done

  if [[ -z "$server_addr" ]]; then
    server_addr="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
  fi

  # ДЕФОЛТЫ
  tls_mode="$(normalize_tls_mode "$tls_mode" || true)"
  [[ -n "$tls_mode" ]] || tls_mode="reality"
  [[ -n "$reality_sni" ]] || reality_sni="eh.vk.com"
  [[ -n "$reality_dest" ]] || reality_dest="eh.vk.com:443"

  if [[ "$non_interactive" != "true" ]]; then
    prompt_required "Публичный адрес сервера (SERVER_ADDR)" "${server_addr:-}" server_addr \
      "Можно IP или домен. (Если подсказка пустая — введи вручную.)"

    while true; do
      prompt_default "Режим TLS: reality или domain" "${tls_mode}" tls_mode
      tls_mode="$(normalize_tls_mode "$tls_mode" || true)"
      [[ -n "$tls_mode" ]] && break
      log_warning "Нужно ввести reality или domain"
    done

    if [[ "$tls_mode" == "domain" ]]; then
      prompt_required "Домен маскировки (A/AAAA -> этот сервер)" "${mask_domain:-}" mask_domain \
        "Пример: vpn.example.com. На него будет выпущен Let's Encrypt сертификат."
      prompt_default "Email для Let's Encrypt (можно пусто)" "${acme_email:-}" acme_email
      prompt_default "Свой certificate_path/fullchain.pem (если уже есть, можно пусто)" "${cert_path:-}" cert_path
      prompt_default "Свой key_path/privkey.pem (если уже есть, можно пусто)" "${key_path:-}" key_path
    else
      prompt_default "Reality SNI (REALITY_SNI)" "${reality_sni}" reality_sni

      while true; do
        prompt_default "Reality DEST (REALITY_DEST host:port)" "${reality_dest}" reality_dest
        reality_dest="$(trim_ws "$reality_dest")"
        if parse_dest "$reality_dest" >/dev/null 2>&1; then
          break
        fi
        log_warning "REALITY_DEST должен быть в формате host:port (пример: example.com:443)"
      done
    fi

    prompt_default "Fingerprint (FINGERPRINT)" "${fp}" fp

    prompt_default "Создать первого клиента. Имя клиента" "${client_name:-user1}" client_name
    client_name="$(trim_ws "$client_name")"
    [[ -z "$client_name" ]] && client_name="user1"
  else
    [[ -n "$server_addr" ]] || die "Non-interactive: не задан --server-addr или XRAYVPN_SERVER_ADDR"
    [[ -n "$client_name" ]] || client_name="user1"
  fi

  tls_mode="$(normalize_tls_mode "$tls_mode" || true)"
  [[ -n "$tls_mode" ]] || die "TLS_MODE должен быть reality или domain"

  if [[ "$tls_mode" == "domain" ]]; then
    [[ -n "$mask_domain" ]] || die "Для --tls-mode domain нужен --mask-domain или XRAYVPN_MASK_DOMAIN"
    is_domain_name "$mask_domain" || die "Некорректный домен: $mask_domain"
  else
    parse_dest "$reality_dest" >/dev/null || die "REALITY_DEST должен быть в формате host:port"
  fi

  # Всегда фикс.
  VLESS_PORT="$FIXED_VLESS_PORT"
  FLOW="$FIXED_FLOW"

  SB_BIN="$SB_BIN_DEFAULT"
  install_singbox

  TLS_MODE="$tls_mode"
  MASK_DOMAIN="$mask_domain"
  ACME_EMAIL="$acme_email"
  if [[ "$TLS_MODE" == "domain" ]]; then
    check_mask_domain_dns "$MASK_DOMAIN" "$server_addr" "$non_interactive"
    ensure_domain_certificate "$MASK_DOMAIN" "$ACME_EMAIL" "$cert_path" "$key_path"
  fi

  # Если уже было установлено — по умолчанию НЕ ломаем клиентов.
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
    : "${PRIVATE_KEY:=}"
    : "${PUBLIC_KEY:=}"
    : "${SHORT_ID:=}"
    : "${CERT_PATH:=}"
    : "${KEY_PATH:=}"

    if [[ "$reset_keys" == "true" ]]; then
      PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
    fi
  fi

  if [[ "$TLS_MODE" == "reality" ]]; then
    if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" || -z "${SHORT_ID:-}" ]]; then
      local kp priv pub
      kp="$(generate_reality_keypair)"
      IFS='|' read -r priv pub <<< "$kp"

      PRIVATE_KEY="$priv"
      PUBLIC_KEY="$pub"
      SHORT_ID="$(generate_short_id)"
    fi
  fi

  SERVER_ADDR="$server_addr"
  REALITY_SNI="$reality_sni"
  REALITY_DEST="$reality_dest"
  FINGERPRINT="$fp"

  write_state_kv

  if [[ ! -f "$CLIENTS_DB" ]]; then
    : > "$CLIENTS_DB"
    chmod 600 "$CLIENTS_DB"
    chown root:root "$CLIENTS_DB"
  fi

  if ! client_exists "$client_name"; then
    add_client "$client_name"
  fi

  render_singbox_config
  install_service_unit
  service_reload

  local self_path
  self_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  if [[ -n "$self_path" ]]; then
    install -m 0755 "$self_path" "/usr/local/bin/$SCRIPT_NAME" 2>/dev/null || true
  fi

  show_client_connection "$client_name"
}

cmd_add() {
  load_state
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена. Сначала: ${SCRIPT_NAME} install"

  local client_name="${1:-}"
  if [[ -z "$client_name" ]]; then
    echo -n "Имя клиента: "
    read -r client_name
  fi
  add_client "$client_name"

  render_singbox_config
  service_reload
}

cmd_remove() {
  load_state
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"

  local client_name="${1:-}"
  if [[ -z "$client_name" ]]; then
    echo -n "Имя клиента: "
    read -r client_name
  fi
  remove_client "$client_name"

  render_singbox_config
  service_reload
}

cmd_list() {
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"
  list_clients
}

cmd_show() {
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"
  local client_name="${1:-}"
  if [[ -z "$client_name" ]]; then
    echo -n "Имя клиента: "
    read -r client_name
  fi
  client_name="$(trim_ws "$client_name")"
  [[ -n "$client_name" ]] || die "Имя пустое"
  client_exists "$client_name" || die "Клиент '${client_name}' не найден"
  show_client_connection "$client_name"
}

cmd_status() {
  service_status
}

cmd_uninstall() {
  ensure_systemd

  log_warning "Удаляю сервис и конфиги xrayvpn..."

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
  fi

  rm -rf "$SB_CONFIG_DIR" || true
  rm -rf "$STATE_DIR" || true

  if [[ -f "/usr/local/bin/$SCRIPT_NAME" ]]; then
    if grep -q "xrayvpn.sh v" "/usr/local/bin/$SCRIPT_NAME" 2>/dev/null && grep -q "(sing-box core)" "/usr/local/bin/$SCRIPT_NAME" 2>/dev/null; then
      rm -f "/usr/local/bin/$SCRIPT_NAME" || true
    else
      log_warning "/usr/local/bin/$SCRIPT_NAME существует, но не похож на этот скрипт — не удаляю ..."
    fi
  fi

  log_success "Готово. sing-box бинарник НЕ удалён."
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    help|--help|-h|"")
      show_help
      return 0
      ;;
  esac

  # Требование: sudo/root в начале (для всех команд, кроме help)
  check_root

  case "$cmd" in
    install)    cmd_install "$@" ;;
    add)        cmd_add "$@" ;;
    remove)     cmd_remove "$@" ;;
    list)       cmd_list ;;
    show)       cmd_show "$@" ;;
    status)     cmd_status ;;
    uninstall)  cmd_uninstall ;;
    *) die "Неизвестная команда: $cmd" ;;
  esac
}

main "$@"
