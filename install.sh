#!/bin/bash

# Check for root privileges
if [ "${EUID}" -ne 0 ]; then
    echo "Please run this script as root (sudo ${0})"
    exit 1
fi

# Get username
usern=$(whoami)
admintoken=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c16)

ARCH=$(uname -m)

if [ "${ARCH}" = "x86_64" ]; then
    ARCH="amd64"
fi

# Check for folder /opt/rustdesk-api-server/
if [ -d "/opt/rustdesk-api-server/" ]; then
    echo "Please remove /opt/rustdesk-api-server/"
    echo "Use rm -rf /opt/rustdesk-api-server/ and run this script again"
    exit 1
fi

# Check the installed Python version
PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')

# Extract major and minor version (e.g., 3.8 from Python 3.8.5)
PYTHON_MAJOR_MINOR=$(echo "${PYTHON_VERSION}" | cut -d. -f1,2)

echo -ne "Enter your preferred domain/DNS address: "
read -r wanip
# Check wanip is valid domain
if ! [[ ${wanip} =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
    echo -e "Invalid domain/DNS address"
    exit 1
fi

# Identify OS
if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=${NAME}
    VER=${VERSION_ID}
    UPSTREAM_ID=${ID_LIKE,,}

    # Fallback to ID_LIKE if ID was not 'ubuntu' or 'debian'
    if [ "${UPSTREAM_ID}" != "debian" ] && [ "${UPSTREAM_ID}" != "ubuntu" ]; then
        UPSTREAM_ID="$(echo ${ID_LIKE,,} | sed s/\"//g | cut -d' ' -f1)"
    fi

elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=${DISTRIB_ID}
    VER=${DISTRIB_RELEASE}
elif [ -f /etc/debian_version ]; then
    # Older Debian, Ubuntu, etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSE-release ]; then
    # Older SuSE, etc.
    OS=SuSE
    VER=$(cat /etc/SuSE-release)
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    OS=RedHat
    VER=$(cat /etc/redhat-release)
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
fi

# Output debugging info if $DEBUG set
if [ "${DEBUG}" = "true" ]; then
    echo "OS: ${OS}"
    echo "VER: ${VER}"
    echo "UPSTREAM_ID: ${UPSTREAM_ID}"
    exit 0
fi

# Setup prereqs for server
# Common named prereqs
PREREQ="curl wget unzip tar git qrencode python${PYTHON_MAJOR_MINOR}-venv"
PREREQDEB="dnsutils ufw"
PREREQRPM="bind-utils"
PREREQARCH="bind"

echo "Installing prerequisites"
if [ "${ID}" = "debian" ] || [ "$OS" = "Ubuntu" ] || [ "$OS" = "Debian" ] || [ "${UPSTREAM_ID}" = "debian" ] || [ "${UPSTREAM_ID}" = "ubuntu" ]; then
    apt update -qq
    apt-get install -y ${PREREQ} ${PREREQDEB} # git
elif [ "$OS" = "CentOS" ] || [ "$OS" = "RedHat" ] || [ "${UPSTREAM_ID}" = "rhel" ] || [ "${OS}" = "Almalinux" ] || [ "${UPSTREAM_ID}" = "Rocky*" ] ; then
# openSUSE 15.4 fails to run the relay service and hangs waiting for it
# Needs more work before it can be enabled
# || [ "${UPSTREAM_ID}" = "suse" ]
    yum update -y
    yum install -y ${PREREQ} ${PREREQRPM} # git
elif [ "${ID}" = "arch" ] || [ "${UPSTREAM_ID}" = "arch" ]; then
    pacman -Syu
    pacman -S ${PREREQ} ${PREREQARCH}
else
    echo "Unsupported OS"
    # Here you could ask the user for permission to try and install anyway
    # If they say yes, then do the install
    # If they say no, exit the script
    exit 1
fi

# Setting up firewall
ufw allow 21115:21119/tcp
ufw allow 22/tcp
ufw allow 21116/udp
ufw enable

# Make folder /var/lib/rustdesk-server/
mkdir -p "/var/lib/rustdesk-server"
chown "${usern}" -R /var/lib/rustdesk-server || exit 1

cd /var/lib/rustdesk-server/ || exit 1

# Download latest version of RustDesk
RDLATEST=$(curl -s https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')

echo "Installing RustDesk Server"
wget "https://github.com/rustdesk/rustdesk-server/releases/download/${RDLATEST}/rustdesk-server-linux-${ARCH}.zip"


unzip -q "rustdesk-server-linux-${ARCH}.zip"
mv "${ARCH}/hbbr" "${ARCH}/hbbs" /usr/bin/
rm -rf "${ARCH}"

chmod +x /usr/bin/hbbs /usr/bin/hbbr

# Make folder /var/log/rustdesk-server/
mkdir -p "/var/log/rustdesk-server"
chown "${usern}" -R /var/log/rustdesk-server

# Setup systemd to launch hbbs
# Add systemd unit file for hbbs and hbbr

# Ensure correct service names are used
service_names=("hbbs" "hbbr")


cat > "/etc/systemd/system/rustdesk-hbbs.service" <<EOF
[Unit]
Description=RustDesk Signal Server
[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/usr/bin/hbbs -r ${wanip} -k _
WorkingDirectory=/var/lib/rustdesk-server/
Environment=ALWAYS_USE_RELAY=Y
User=${usern}
Group=${usern}
Restart=always
StandardOutput=append:/var/log/rustdesk-server/hbbs.log
StandardError=append:/var/log/rustdesk-server/hbbs.error
# Restart service after 10 seconds if node service crashes
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

cat > "/etc/systemd/system/rustdesk-hbbr.service" <<EOF
[Unit]
Description=RustDesk Relay Server
[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/usr/bin/hbbr -k _
WorkingDirectory=/var/lib/rustdesk-server/
User=${usern}
Group=${usern}
Restart=always
StandardOutput=append:/var/log/rustdesk-server/hbbr.log
StandardError=append:/var/log/rustdesk-server/hbbr.error
# Restart service after 10 seconds if node service crashes
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# Enable and start services
for service_name in "${service_names[@]}"; do
    systemctl enable --now "rustdesk-${service_name}.service"
done

# Ensure services are ready
for service_name in "${service_names[@]}"; do
    while ! systemctl is-active --quiet "rustdesk-${service_name}.service"; do
        echo -ne "RustDesk ${service_name} not ready yet...\n"
        sleep 3
    done
done

# Retrieve public key file and key
pubname=$(find /var/lib/rustdesk-server/ -name "*.pub")
key=$(cat "${pubname}")

echo "Tidying up install"
rm -rf rustdesk-server-linux-${ARCH}.zip ${ARCH}

cd /opt

git clone https://github.com/infiniteremote/rustdesk-api-server.git

chown -R ${usern}:${usern} /opt/rustdesk-api-server/


SECRET_KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 80 | head -n 1)
UNISALT=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 24 | head -n 1)

cat <<EOF > /opt/rustdesk-api-server/rustdesk_server_api/secret_config.py
SECRET_KEY = "${SECRET_KEY}"
SALT_CRED = "${UNISALT}"
CSRF_TRUSTED_ORIGINS = ["https://${wanip}"]
EOF

mkdir -p /var/log/rustdesk-server-api/


chown -R ${usern}:${usern} /var/log/rustdesk-server-api/

cd /opt/rustdesk-api-server/api
python3 -m venv env
source /opt/rustdesk-api-server/api/env/bin/activate
cd /opt/rustdesk-api-server/api/
pip install --no-cache-dir --upgrade pip
pip install --no-cache-dir setuptools wheel
pip install --no-cache-dir -r /opt/rustdesk-api-server/requirements.txt
cd /opt/rustdesk-api-server/
python manage.py makemigrations
python manage.py migrate
echo "Please Set your password and username for the Web UI"
python manage.py securecreatesuperuser
deactivate

apiconfig="$(
  cat <<EOF
bind = "127.0.0.1:8000"
workers = 4  # Number of worker processes (adjust as needed)
timeout = 120  # Maximum request processing time
user = "${usern}"  # User to run Gunicorn as
group = "${usern}"  # Group to run Gunicorn as

wsgi_app = "rustdesk_server_api.wsgi:application"

# Logging
errorlog = "/var/log/rustdesk-server-api/error.log"
accesslog = "/var/log/rustdesk-server-api/access.log"
loglevel = "info"
EOF
)"
echo "${apiconfig}" > /opt/rustdesk-api-server/api/api_config.py

apiservice="$(
  cat <<EOF
[Unit]
Description=rustdesk-api-server gunicorn daemon

[Service]
User=${usern}
WorkingDirectory=/opt/rustdesk-api-server/
Environment="PATH=/opt/rustdesk-api-server/api/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/rustdesk-api-server/api/env/bin/gunicorn -c /opt/rustdesk-api-server/api/api_config.py
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
)"
echo "${apiservice}" > /etc/systemd/system/rustdesk-api.service

systemctl daemon-reload
systemctl enable --now rustdesk-api

echo "Installing nginx"
# Prompt user for whether Nginx and valid certificate are installed
while true; do
    read -p "Do you already have Nginx and a valid certificate installed? (yes/no) " certInstalled
    case "${certInstalled}" in
        [Yy]|[Yy][Ee][Ss])
            certInstalled="yes"
            break
            ;;
        [Nn]|[Nn][Oo])
            certInstalled="no"
            break
            ;;
        *)
            echo "Please enter only 'yes' or 'no'."
            ;;
    esac
done

if [ "${certInstalled}" = "yes" ]; then
    echo "Certificates already installed. Skipping installation of Nginx and Certbot."
    # Prompt user for certificate and key file paths
    read -p "Enter the path to your .crt and .key files (e.g., /root/example.com): " cert_path

    # Extract file name from the given path
    file_name=$(basename "${cert_path}")

    # Get directory part of the path
    directory=$(dirname "${cert_path}")

    # Construct full paths for .crt and .key files
    crt_file="${directory}/${file_name}.crt"
    key_file="${directory}/${file_name}.key"

    # Nginx configuration
    cat <<EOF > /etc/nginx/sites-available/rustdesk.conf
server {
    listen 80;
    server_name ${wanip};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${wanip};

    ssl_certificate ${crt_file};
    ssl_certificate_key ${key_file};

    location / {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF


else
    echo "Installing nginx and Certbot"

    if [ "${ID}" = "debian" ] || [ "${OS}" = "Ubuntu" ] || [ "${OS}" = "Debian" ] || [ "${UPSTREAM_ID}" = "ubuntu" ] || [ "${UPSTREAM_ID}" = "debian" ]; then
        apt -y install nginx
        apt -y install python3-certbot-nginx
    elif [ "${OS}" = "CentOS" ] || [ "${OS}" = "RedHat" ] || [ "${UPSTREAM_ID}" = "rhel" ] || [ "${OS}" = "Almalinux" ] || [ "${UPSTREAM_ID}" = "Rocky*" ] ; then
    # openSUSE 15.4 fails to run the relay service and hangs waiting for it
    # Needs more work before it can be enabled
    # || [ "${UPSTREAM_ID}" = "suse" ]
        yum -y install nginx
        yum -y install python3-certbot-nginx
    elif [ "${ID}" = "arch" ] || [ "${UPSTREAM_ID}" = "arch" ]; then
        pacman -S install nginx
        pacman -S install python3-certbot-nginx
    else
        echo "Unsupported OS"
        # Here you could ask the user for permission to try and install anyway
        # If they say yes, then do the install
        # If they say no, exit the script
        exit 1
    fi


    cat <<EOF > /etc/nginx/sites-available/rustdesk.conf
server {
    server_name ${wanip};
    location / {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

fi

# Check for nginx default files
if [ -f "/etc/nginx/sites-available/default" ]; then
    rm /etc/nginx/sites-available/default
fi
if [ -f "/etc/nginx/sites-enabled/default" ]; then
    rm /etc/nginx/sites-enabled/default
fi

ln -s /etc/nginx/sites-available/rustdesk.conf /etc/nginx/sites-enabled/rustdesk.conf

ufw allow 80/tcp
ufw allow 443/tcp

ufw enable 
ufw reload

if [ "${certInstalled}" = "no" ]; then
    certbot --nginx -d ${wanip}
fi

echo "Grabbing installers"
string="{\"host\":\"${wanip}\",\"key\":\"${key}\",\"api\":\"https://${wanip}\"}"
string64=$(echo -n "${string}" | base64 -w 0 | tr -d '=')
string64rev=$(echo -n "${string64}" | rev)

echo "${string64rev}"

# Fetch the latest release information for Rustdesk using GitHub API
release_info=$(wget -O- https://api.github.com/repos/rustdesk/rustdesk/releases/latest)

# Extract the download URL for the executable
download_url=$(echo "${release_info}" | grep "browser_download_url" | head -n 1 | cut -d '"' -f 4)

# Extract the filename from the download URL
filename=$(basename "${download_url}")

# Set the destination directory
dest_dir="/opt/rustdesk-api-server/static/configs"

# Make sure the destination directory exists
mkdir -p "${dest_dir}"

# Download the executable to the destination directory
wget -O "${dest_dir}/rustdesk-licensed-${string64rev}.exe" "${download_url}"

# Exit if the download fails
if [ $? -ne 0 ]; then
    echo "Error: Failed to download ${filename}"
    exit 1
fi

# Download successful
echo "Downloaded ${filename} to ${dest_dir}"

sed -i "s|secure-string|${string64rev}|g" /opt/rustdesk-api-server/api/templates/installers.html
sed -i "s|UniqueKey|${key}|g" /opt/rustdesk-api-server/api/templates/installers.html
sed -i "s|UniqueURL|${wanip}|g" /opt/rustdesk-api-server/api/templates/installers.html
sed -i "s|secure-string|${string64rev}|g" /opt/rustdesk-api-server/static/configs/install.ps1
sed -i "s|secure-string|${string64rev}|g" /opt/rustdesk-api-server/static/configs/install.bat
sed -i "s|secure-string|${string64rev}|g" /opt/rustdesk-api-server/static/configs/install-mac.sh
sed -i "s|secure-string|${string64rev}|g" /opt/rustdesk-api-server/static/configs/install-linux.sh

qrencode -o /opt/rustdesk-api-server/static/configs/qrcode.png config=${string64rev}
