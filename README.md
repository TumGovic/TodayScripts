# TodayScripts

Shell-скрипты для быстрой настройки Ubuntu-сервера: root-доступ по SSH и VPN/chain на базе sing-box.

## Быстрый запуск на Ubuntu

Три команды запуска напрямую через GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/TumGovic/TodayScripts/main/root.sh -o /tmp/root.sh && sudo bash /tmp/root.sh
```

```bash
curl -fsSL https://raw.githubusercontent.com/TumGovic/TodayScripts/main/xrayvpn.sh -o /tmp/xrayvpn.sh && sudo bash /tmp/xrayvpn.sh install
```

```bash
curl -fsSL https://raw.githubusercontent.com/TumGovic/TodayScripts/main/xraychain.sh -o /tmp/xraychain.sh && sudo bash /tmp/xraychain.sh install
```

## Скрипты

- `root.sh` - включает вход под root по SSH с паролем на Ubuntu. При необходимости ставит `openssh-server`, задает пароль root, делает бэкапы SSH-конфигов, добавляет отдельный конфиг для root/password login, проверяет `sshd` и перезапускает SSH.
- `xrayvpn.sh` - устанавливает и обслуживает VPN-сервис VLESS на базе sing-box на TCP/443 с прямым outbound. Скрипт нужен для быстрого поднятия собственного VPN-сервера: можно выбрать старый режим `reality` с VLESS Reality или режим `domain`, где используется свой домен, обычный TLS-сертификат и VLESS TLS. В режиме `domain` домен должен указывать A/AAAA-записью на сервер; скрипт проверяет DNS, может выпустить Let's Encrypt сертификат через `certbot` или использовать готовые `fullchain.pem`/`privkey.pem`. Поддерживает установку, добавление/удаление/список клиентов, показ URI/QR, статус и удаление конфигов сервиса.
- `xraychain.sh` - устанавливает и обслуживает цепочку на базе sing-box: VLESS Reality inbound и outbound через `ss://` или `vless://` URI. Поддерживает клиентов, парсинг/обновление outbound URI, статус и удаление конфигов сервиса.

## Примечания

- Скрипты нужно запускать от root или через `sudo`.
- VPN-скрипты хранят состояние в `/etc/xrayvpn` или `/etc/xraychain` и создают systemd-сервисы `xrayvpn` или `xraychain`.
- `root.sh` меняет настройки SSH-аутентификации. Используйте его только там, где вход root по паролю действительно нужен.

## Пример запуска `xrayvpn.sh` со своим доменом

```bash
curl -fsSL https://raw.githubusercontent.com/TumGovic/TodayScripts/main/xrayvpn.sh -o /tmp/xrayvpn.sh && sudo bash /tmp/xrayvpn.sh install --tls-mode domain --mask-domain vpn.example.com --server-addr 1.2.3.4 --acme-email you@example.com
```

Перед запуском замените `vpn.example.com`, `1.2.3.4` и email на свои значения. Порт `443` должен быть свободен для sing-box, а порт `80` должен быть свободен на время выпуска Let's Encrypt сертификата.
