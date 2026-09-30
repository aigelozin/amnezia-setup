#!/bin/bash
# Установка сервера AmneziaWG + конфиг первого клиента (Часть 2 инструкции).
# Запуск на сервере от root:  bash awg-install.sh
set -euo pipefail

ENDPOINT_IP="103.115.18.49"
DIR=/etc/amnezia/amneziawg

if [ -f "$DIR/awg0.conf" ]; then
  echo "Уже установлено: $DIR/awg0.conf существует. Выход."; exit 1
fi

echo "== Шаг 2: включаю deb-src"
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
else
  sed -i 's/^# *deb-src/deb-src/' /etc/apt/sources.list
fi
apt-get update

echo "== Шаг 3: зависимости и AmneziaWG"
if ! apt-get install -y linux-headers-$(uname -r); then
  echo "Нет заголовков для ядра $(uname -r)."
  echo "Выполни: apt update && apt full-upgrade -y && reboot, затем запусти скрипт снова."
  exit 1
fi
apt-get install -y software-properties-common python3-launchpadlib gnupg2 iptables qrencode
add-apt-repository -y ppa:amnezia/ppa
apt-get install -y amneziawg
modprobe amneziawg
awg --version

echo "== Шаг 4: пересылка трафика"
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-awg.conf
sysctl --system >/dev/null

echo "== Шаг 5: ключи"
mkdir -p "$DIR" && cd "$DIR"
umask 077
awg genkey | tee server.key | awg pubkey > server.pub
awg genkey | tee client1.key | awg pubkey > client1.pub

echo "== Шаг 6: сетевой интерфейс"
IFACE=$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
echo "Интерфейс: $IFACE"

# Случайные параметры обфускации по правилам из таблицы инструкции
PORT=$(shuf -i 10000-65000 -n 1)
JC=$(shuf -i 4-12 -n 1)
S1=$(shuf -i 15-150 -n 1)
while :; do S2=$(shuf -i 15-150 -n 1); [ $((S1 + 56)) -ne "$S2" ] && break; done
read -r H1 H2 H3 H4 <<< "$(shuf -i 5-2147483647 -n 4 | tr '\n' ' ')"
OBF="Jc = $JC
Jmin = 8
Jmax = 80
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4"

echo "== Шаг 7: конфиг сервера"
cat > awg0.conf <<EOF
[Interface]
PrivateKey = $(cat server.key)
Address = 10.8.0.1/24
ListenPort = $PORT

$OBF

PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE

[Peer]
# client1
PublicKey = $(cat client1.pub)
AllowedIPs = 10.8.0.2/32
EOF

echo "== Шаг 10: конфиг клиента"
cat > client1.conf <<EOF
[Interface]
PrivateKey = $(cat client1.key)
Address = 10.8.0.2/32
DNS = 1.1.1.1

$OBF

[Peer]
PublicKey = $(cat server.pub)
Endpoint = $ENDPOINT_IP:$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "== Шаг 8: запуск и автозапуск"
systemctl enable --now awg-quick@awg0
awg show

echo "== Шаг 9: порт"
if ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT"/udp
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw reload
fi

echo
echo "== Шаг 11: QR-код для приложения Amnezia"
qrencode -t ansiutf8 < client1.conf
echo
echo "ГОТОВО. UDP-порт VPN: $PORT — открой его в панели хостинга, если там есть firewall."
echo "Конфиг клиента: $DIR/client1.conf"
echo "Проверка после подключения клиента: awg show  (ищи 'latest handshake')"
