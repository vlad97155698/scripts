#!/bin/bash

echo ""
echo "Добро пожаловать в Настройщик Сервера с Нуля!"
echo ""


if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "[*] Этот скрипт должен быть запущен от пользователя root."
    echo ""
    exit 1
fi

SCRIPT_VERSION=3
VERSION_FILE="/var/www/version"

# Получаем список сетевых интерфейсов и их адресов
interfaces_and_addresses=$(ip addr show | awk '/^[0-9]+:/ {if (interface != "") print interface ": " address; interface=$2; address=""; next} /inet / {split($2, parts, "/"); address=parts[1]} END {if (interface != "") print interface ": " address}' | nl)

# Выводим список всех интерфейсов и их адресов с номерами
echo "Сетевые интерфейсы и их адреса:"
echo "$interfaces_and_addresses"
echo ""

# Запрашиваем у пользователя номер входного сетевого интерфейса
read -p "Введите номер входного сетевого интерфейса: " input_interface_number

# Запрашиваем у пользователя номер выходного сетевого интерфейса
read -p "Введите номер выходного сетевого интерфейса: " output_interface_number

# Получаем имена входного и выходного сетевых интерфейсов по номерам
input_interface=$(ip -o link show | awk -v num="$input_interface_number" -F': ' '$1 == num {print $2}')
output_interface=$(ip -o link show | awk -v num="$output_interface_number" -F': ' '$1 == num {print $2}')

# Выводим выбранные интерфейсы для подтверждения
echo ""
echo "Входной сетевой интерфейс: $input_interface"
echo "Выходной сетевой интерфейс: $output_interface"

# Показываем пользователю варианты настройки сетевых подключений
echo ""
echo "Выберите вариант настройки сетевых подключений:"
echo "1) Получить адрес от DHCP"
echo "2) Прописать статический адрес"
echo ""

# Проверка настроек сетевых подключений
read -p "Выберите вариант [1/2]: " choice
echo ""
sudo rm -f /etc/netplan/*


if [ "$choice" == "1" ]; then
    # Конфигурация для DHCP
    cat <<EOF > /etc/netplan/01-network-manager-all.yaml
network:
  renderer: networkd
  ethernets:
    $output_interface:
      dhcp4: false
      addresses: [10.50.1.1/20]
      nameservers:
        addresses: [10.50.1.1]
      optional: true
    $input_interface:
      dhcp4: true
  version: 2
EOF
elif [ "$choice" == "2" ]; then
    # Конфигурация для статического адреса
    read -p "Введите IP-адрес: " address
    read -p "Введите маску подсети [24]: " subnet_mask
    read -p "Введите шлюз: " gateway
    read -p "Введите DNS1: " dns1
    read -p "Введите DNS2: " dns2

    cat <<EOF > /etc/netplan/01-network-manager-all.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $output_interface:
      dhcp4: false
      addresses: [10.50.1.1/20]
      nameservers: 
        addresses: [10.50.1.1]
      optional: true   
    $input_interface:
      dhcp4: false
      addresses: [$address/$subnet_mask]
      gateway4: $gateway
      nameservers: 
        addresses: [$dns1, $dns2]
EOF
else
    echo "Неверный выбор."
    exit 1
fi


echo ""
echo "[*] Применяем настройки сети..."
echo ""
netplan apply

sleep 7

echo ""
echo "[*] Проверка доступа в интернет..."
echo ""
ping -q -c1 google.com &>/dev/null && { echo ""; echo "[*] Интернет соединение доступно."; echo ""; } || { echo ""; echo "[*] Ошибка: Интернет соединение недоступно. Пожалуйста, убедитесь, что сервер подключен к сети."; echo ""; exit 1; }



echo ""
echo "[*] Установка нужных компонентов..."
echo ""
apt-get update
apt-get upgrade -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y htop net-tools mtr network-manager dnsmasq wireguard openvpn apache2 php php-yaml libapache2-mod-php git iptables-persistent openssh-server resolvconf 

# Файл, который необходимо изменить
RESOLV_CONF="/etc/resolvconf/resolv.conf.d/base"
RESOLV_CONF2="/etc/resolv.conf"

# DNS серверы, которые вы хотите добавить
DNS1="nameserver 1.1.1.1"
DNS2="nameserver 8.8.8.8"

# Проверка и добавление первого DNS сервера, если он отсутствует
grep -qxF "$DNS1" "$RESOLV_CONF" || echo "$DNS1" | sudo tee -a "$RESOLV_CONF"

# Проверка и добавление второго DNS сервера, если он отсутствует
grep -qxF "$DNS2" "$RESOLV_CONF" || echo "$DNS2" | sudo tee -a "$RESOLV_CONF"

# Проверка и добавление первого DNS сервера, если он отсутствует
grep -qxF "$DNS1" "$RESOLV_CONF2" || echo "$DNS1" | sudo tee -a "$RESOLV_CONF2"

# Проверка и добавление второго DNS сервера, если он отсутствует
grep -qxF "$DNS2" "$RESOLV_CONF2" || echo "$DNS2" | sudo tee -a "$RESOLV_CONF2"

sudo resolvconf -u

echo ""
echo "[*] Разрешаеам руту подключатся по SSH..."
echo ""
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd


echo ""
echo "[*] Настройка DHCP сервера..."
echo ""
# Путь к конфигурационному файлу dnsmasq
config_file="/etc/dnsmasq.conf"

# Добавляем необходимые параметры в конфигурационный файл dnsmasq
cat <<EOF | sudo tee -a $config_file
dhcp-authoritative
domain=link.lan
listen-address=127.0.0.1,10.50.1.1
dhcp-range=10.10.1.2,10.10.15.254,255.255.240.0,12h
server=8.8.8.8
server=8.8.4.4
cache-size=10000
EOF

sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo systemctl restart dnsmasq
sudo systemctl enable dnsmasq


echo ""
echo "[*] Создаем правила трафика..."
echo ""

sudo sed -i '/^#.*net.ipv4.ip_forward/s/^#//' /etc/sysctl.conf
sudo sysctl -p
sudo iptables -t nat -A POSTROUTING -o tun0 -s 10.50.1.0/20 -j MASQUERADE
sudo iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
sudo iptables-save > /etc/iptables/rules.v4


echo ""
echo "[*] Настройка VPN протоколов..."
echo ""
sudo sed -i '/^#\s*AUTOSTART="all"/s/^#\s*//' /etc/default/openvpn


echo ""
echo "[*] Установка ЛК..."
echo ""
chmod 777 /etc/openvpn/
chmod 777 /etc/wireguard/
chmod 666 /etc/netplan/01-network-manager-all.yaml
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop openvpn*, /bin/systemctl start openvpn*" >> /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop wg-quick*, /bin/systemctl start wg-quick*" >> /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl enable wg-quick*, /bin/systemctl disable wg-quick*" >> /etc/sudoers
echo "www-data ALL=(root) NOPASSWD: /usr/bin/id" >> /etc/sudoers
echo "www-data ALL=(ALL) NOPASSWD: /usr/sbin/netplan try, /usr/sbin/netplan apply" >> /etc/sudoers
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables-save > /etc/iptables/rules.v4
sudo iptables-save | sudo tee /etc/iptables/rules.v4
sudo service iptables restart
rm /var/www/html/*
sudo git clone https://github.com/MineVPN/WebVPNCabinet.git /var/www/html


echo ""
echo "[*] Установка сервиса обновлений..."
echo ""
LAUNCHER_PATH="/usr/local/bin/run-update.sh"

# Создаем файл загрузчика
echo "   Создаю $LAUNCHER_PATH..."
sudo tee $LAUNCHER_PATH > /dev/null << 'EOF'
#!/bin/bash
cd /var/www/html/ || exit
echo "Обновляем ЛК..."
sudo git fetch origin
sudo git reset --hard origin/main
sudo git clean -df
sudo chmod +x /var/www/html/update.sh
echo "Запускаем скрипт обновления update.sh..."
/var/www/html/update.sh
EOF
        
# Делаем загрузчик исполняемым
echo "Делаю загрузчик исполняемым..."
sudo chmod +x $LAUNCHER_PATH

# Помещаем запись в crontab
echo "0 4 * * * /bin/bash /usr/local/bin/run-update.sh" | sudo crontab -
echo ""
echo "[*] Установка сервиса обновлений завершена"
echo ""


echo ""
echo "[*] Установка сервиса автоанализа и восстановления VPN-тонелей..."
echo ""


chmod 777 /var/www/settings
# Создание скрипта проверки (установка) ---
echo "⚙️  Создание универсального скрипта проверки в /usr/local/bin/vpn-healthcheck.sh..."
cat > /usr/local/bin/vpn-healthcheck.sh << 'EOF'
#!/bin/bash

# --- Конфигурация ---
INTERFACE="tun0"
SETTINGS_FILE="/var/www/settings"
IP_CHECK_SERVICE="ifconfig.me"

# --- Функции ---
log() {
    logger -t VPNCheck "$1"
    echo "$1"
}

# --- Основная логика ---

# 1. Проверяем, разрешена ли проверка в файле настроек.
if [ -f "$SETTINGS_FILE" ] && ! grep -q "^vpnchecker=true$" "$SETTINGS_FILE" 2>/dev/null; then
    exit 0 # Проверка выключена, тихо выходим
fi

# 2. Убедимся, что интерфейс tun0 вообще существует.
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    #log "Интерфейс ${INTERFACE} не активен."

    # Проверяем, разрешено ли автоподнятие туннеля
    if grep -q "^autoupvpn=true$" "$SETTINGS_FILE" 2>/dev/null; then
        # Да, автоподнятие разрешено.
        #log "Настройка 'autoupvpn=true' активна. Пытаемся поднять интерфейс..."
        
        if [ -f "/etc/wireguard/${INTERFACE}.conf" ]; then
            #log "Перезапускаем WireGuard (wg-quick@${INTERFACE})..."
            systemctl restart "wg-quick@${INTERFACE}"
        elif [ -f "/etc/openvpn/${INTERFACE}.conf" ]; then
            #log "Перезапускаем OpenVPN (openvpn@${INTERFACE})..."
            systemctl restart "openvpn@${INTERFACE}"
        else
            #log "Конфигурационные файлы VPN не найдены. Нечего перезапускать."
        fi
        
    else
        # Нет, автоподнятие запрещено или файл/настройка отсутствуют.
        #log "Автоподнятие интерфейса отключено в настройках. Выход."
    fi
    
    # В любом случае выходим из скрипта, так как интерфейса нет и дальнейшие проверки бессмысленны.
    exit 1
fi

# 3. ДИНАМИЧЕСКАЯ ПРОВЕРКА МАРШРУТИЗАЦИИ (по вашей идее)
# Получаем публичный IP через маршрут по умолчанию
DEFAULT_ROUTE_IP=$(curl -s --max-time 5 "$IP_CHECK_SERVICE")

# Получаем публичный IP, принудительно используя интерфейс tun0
TUN0_ROUTE_IP=$(curl -s --interface "$INTERFACE" --max-time 5 "$IP_CHECK_SERVICE")

# 4. Анализ результатов
# Сначала проверяем, удалось ли вообще получить IP
if [[ -z "$DEFAULT_ROUTE_IP" || -z "$TUN0_ROUTE_IP" ]]; then
    #log "Не удалось получить один или оба IP-адреса для сравнения. Возможно, полное отсутствие интернета."
    # Определяем, какой сервис перезапускать
    if [ -f "/etc/wireguard/${INTERFACE}.conf" ]; then
        #log "Перезапускаем WireGuard (wg-quick@${INTERFACE})..."
        systemctl restart "wg-quick@${INTERFACE}"
    elif [ -f "/etc/openvpn/${INTERFACE}.conf" ]; then
        #log "Перезапускаем OpenVPN (openvpn@${INTERFACE})..."
        systemctl restart "openvpn@${INTERFACE}"
    fi
    exit 1
fi

# Теперь главная проверка: сравниваем IP
if [[ "$DEFAULT_ROUTE_IP" != "$TUN0_ROUTE_IP" ]]; then
    #log "ОБНАРУЖЕНА УТЕЧКА МАРШРУТА!"
    #log "   -> IP по умолчанию: $DEFAULT_ROUTE_IP (неправильный)"
    #log "   -> IP через tun0: $TUN0_ROUTE_IP (правильный)"
    
    # Определяем, какой сервис перезапускать
    if [ -f "/etc/wireguard/${INTERFACE}.conf" ]; then
        #log "Перезапускаем WireGuard для исправления маршрутизации..."
        systemctl restart "wg-quick@${INTERFACE}"
    elif [ -f "/etc/openvpn/${INTERFACE}.conf" ]; then
        #log "Перезапускаем OpenVPN для исправления маршрутизации..."
        systemctl restart "openvpn@${INTERFACE}"
    fi
    exit 1
else
    #log "Проверка пройдена. Маршрутизация в порядке (Публичный IP: $DEFAULT_ROUTE_IP)."
    exit 0
fi
EOF

# --- Установка прав на выполнение скрипта ---
chmod +x /usr/local/bin/vpn-healthcheck.sh
echo "✅  Скрипт создан и сделан исполняемым."

# Установка службы и таймера ---
echo "⚙️  Создание файла службы /etc/systemd/system/vpn-healthcheck.service..."
cat > /etc/systemd/system/vpn-healthcheck.service << 'EOF'
[Unit]
Description=VPN Health Check Service
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-healthcheck.sh
EOF
echo "✅  Файл службы создан."

echo "⚙️  Создание файла таймера /etc/systemd/system/vpn-healthcheck.timer..."
cat > /etc/systemd/system/vpn-healthcheck.timer << 'EOF'
[Unit]
Description=Run VPN Health Check Service periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=10s
Unit=vpn-healthcheck.service

[Install]
WantedBy=timers.target
EOF
echo "✅  Файл таймера создан."

cat > /var/www/settings << EOF
vpnchecker=true
autoupvpn=true
EOF

echo "🚀  Перезагрузка systemd, включение и запуск таймера..."
systemctl daemon-reload
systemctl stop vpn-healthcheck.timer >/dev/null 2>&1
systemctl enable --now vpn-healthcheck.timer

# --- Финальное сообщение ---
echo ""
echo "[*] Установка сервиса автоанализа и восстановления VPN-тонелей завершена."
echo ""

echo "$SCRIPT_VERSION" | sudo tee "$VERSION_FILE" > /dev/null


echo ""
echo "[*] Установка и настройка сервера полностью Завершена!"
echo ""
echo "Вы можете перейти в ЛК для установки конфига"
echo "Ссылка http://10.50.1.1/ для подключения с локальной сети"
echo "Пароль от ЛК такойже как от пользователя root"
echo ""
