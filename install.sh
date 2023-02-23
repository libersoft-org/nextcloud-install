#!/usr/bin/env bash

grep -q 'ID=debian' /etc/os-release &> /dev/null
if [[ $? -ne 0 ]]; then
 echo "This script works only on Debian-like systems."
 exit 1
fi

ask_input() {
 local -r TEXT="${1}"
 local -r VAL_NAME="${2}"
 echo -n "${TEXT}: "
 read -r "${VAL_NAME?}"
}

ask_optional() {
 local -r TEXT="${1}"
 local -r VAL_NAME="${2}"
 read -r -p "${TEXT} [y/n] " yn
 case $yn in 
  y|Y|yes ) export "${VAL_NAME}"=1; ;; 
  n|N|no )  export "${VAL_NAME}"=0; ;;
  * )     echo "Ivalid choice!"; exit 1; ;;
 esac
}

ask_all() {
 ask_input "Domain"                      DOMAIN
 ask_input "Nextcloud admin user"        NEXTCLOUD_ADMIN_USER
 ask_input "Nextcloud admin password"    NEXTCLOUD_ADMIN_PASSWORD
 ask_input "Nextcloud root path"         NEXTCLOUD_ROOT_PATH
 ask_input "Nextcloud db name"           NEXTCLOUD_DB_NAME
 ask_input "Nextcloud db user"           NEXTCLOUD_DB_USER
 ask_input "Nextcloud db password"       NEXTCLOUD_DB_PASSWORD
 ask_input "PHP version"                 PHP_VERSION
 ask_input "Mail from address"           MAIL_FROM_ADDRESS
 ask_input "Mail sender domain"          MAIL_SENDER_DOMAIN
 ask_input "Mail smtp host"              MAIL_SMTP_HOST
 ask_optional "Enable smtp auth?"        MAIL_SMTP_AUTH_ENABLED
 if [[ ${MAIL_SMTP_AUTH_ENABLED} -eq 1 ]]; then
  ask_input "Mail smtp user"          MAIL_SMTP_USER
  ask_input "Mail smtp password"      MAIL_SMTP_PASSWORD
 fi
}

prepare_system() {
 apt update
 apt -y dist-upgrade
 apt -y install util-linux rsync curl gnupg2 ca-certificates lsb-release debian-archive-keyring unzip wget mariadb-server mariadb-client certbot libmagickcore-dev php"${PHP_VERSION}"-{fpm,curl,dom,gd,mbstring,zip,mysql,intl,gmp,bcmath,imagick,bz2,apcu}
 curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg > /dev/null
 gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg
 echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list
 echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | tee /etc/apt/preferences.d/99nginx
 apt -y install nginx
}

set_php_fpm() {
 pushd "/etc/php/${PHP_VERSION}/fpm/"
 sed -i '
  /\bmemory_limit = .*/                       { s//memory_limit = 2048M/; }
  /\bupload_max_filesize = .*/                { s//upload_max_filesize = 102400M/; }
  /\bpost_max_size = .*/                      { s//post_max_size = 902400M/; }
  /\bmax_execution_time = .*/                 { s//max_execution_time = 86400/; }
  /;\?date\.timezone =.*/                     { s//date\.timezone = "Europe\/Prague"/; }
  /output_buffering = .*/                     { s//output_buffering = Off/; }
  /;\?upload_tmp_dir =.*/                     { s//upload_tmp_dir = \/data\/tmp/; }
  /;\?zend_extension=opcache/                 { s//zend_extension=opcache/; }
  /;\?opcache\.enable=.*/                     { s//opcache\.enable=1/; }
  /;\?opcache\.interned_strings_buffer=.*/    { s//opcache\.interned_strings_buffer=64/; }
  /;\?opcache\.max_accelerated_files=.*/      { s//opcache\.max_accelerated_files=10000/; }
  /;\?opcache\.memory_consumption=.*/         { s//opcache\.memory_consumption=256/; }
  /;\?opcache\.save_comments=.*/              { s//opcache\.save_comments=1/; }
  /;\?opcache\.revalidate_freq=.*/            { s//opcache\.revalidate_freq=1/; }
  /;\?post_max_size = .*/                     { s//post_max_size = 902400M/; }
  /;\?max_input_time = .*/                    { s//max_input_time = 86400/; }
  /;\?env\[PATH\] =.*/                        { s//env\[PATH\] = \/usr\/local\/bin:\/usr\/bin:\/bin/; }
 ' ./php.ini
 sed -i '
  /;\?clear_env =.*/   { s//clear_env = no/; }
 ' pool.d/www.conf
 popd
 # debian starts fpm by default but we want to be idiot proof
 systemctl enable "php${PHP_VERSION}-fpm.service"
 systemctl stop "php${PHP_VERSION}-fpm.service"
 systemctl start "php${PHP_VERSION}-fpm.service"
}


set_https_certs()
{
 systemctl stop nginx
 certbot certonly --standalone --register-unsafely-without-email --agree-tos -d "${DOMAIN}"
}

prepare_db()
{
 systemctl enable mariadb
 systemctl start mariadb
 sleep 1
 mysql -e "CREATE DATABASE IF NOT EXISTS ${NEXTCLOUD_DB_NAME}"
 mysql -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, CREATE TEMPORARY TABLES ON ${NEXTCLOUD_DB_USER}.* TO ${NEXTCLOUD_DB_USER}@localhost IDENTIFIED BY '${NEXTCLOUD_DB_PASSWORD}'"
 mysql -e "FLUSH privileges"
}

set_nginx() {
 local VHOST_CONF_PATH="${DOMAIN}.conf"
 pushd /etc/nginx/
 # disable http2
 pushd ./sites-enabled
 sed -i '
  /\blisten / { s/\bhttp2\b//; }
 ' default
 # set vhost - not populated by bash!
 cat << 'EOF' > "${VHOST_CONF_PATH}"
upstream php-handler {
 server unix:${PHP_FPM_SOCKET_PATH};
}

map $arg_v $asset_immutable {
 "" "";
 default "immutable";
}

server {
 listen 80;
 listen [::]:80;
 server_name ${DOMAIN};
 access_log ${NEXTCLOUD_ROOT_PATH}/log/www/access-http.log;
 error_log ${NEXTCLOUD_ROOT_PATH}/log/www/error-http.log;
 if ($host = ${DOMAIN}) {
  return 301 https://$host$request_uri;
 }
}

server {
 listen [::]:443 ssl;
 listen 443 ssl;
 server_name ${DOMAIN};
 root ${NEXTCLOUD_ROOT_PATH}/www/;
 ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
 ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
 server_tokens off;
 index index.php index.html index.htm /index.php$request_uri;
 access_log ${NEXTCLOUD_ROOT_PATH}/log/www/access-https.log;
 error_log ${NEXTCLOUD_ROOT_PATH}/log/www/error-https.log;
 client_max_body_size 20G;
 client_body_timeout 3600s;
 client_body_buffer_size 1024k;
 fastcgi_buffers 64 4K;
 fastcgi_read_timeout 86400;
 gzip on;
 gzip_vary on;
 gzip_comp_level 4;
 gzip_min_length 256;
 gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
 gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;
 add_header Referrer-Policy "no-referrer" always;
 add_header X-Content-Type-Options "nosniff" always;
 add_header X-Download-Options "noopen" always;
 add_header X-Frame-Options "SAMEORIGIN" always;
 add_header X-Permitted-Cross-Domain-Policies "none" always;
 add_header X-Robots-Tag "none" always;
 add_header X-XSS-Protection "1; mode=block" always;
 add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
 fastcgi_hide_header X-Powered-By;

 location = / {
  if ( $http_user_agent ~ ^DavClnt ) {
   return 302 /remote.php/webdav/$is_args$args;
  }
 }

 location = /robots.txt {
  allow all;
  log_not_found off;
  access_log off;
 }

 location ^~ /.well-known {
  location = /.well-known/carddav { return 301 /remote.php/dav/; }
  location = /.well-known/caldav { return 301 /remote.php/dav/; }
  location /.well-known/acme-challenge { try_files $uri $uri/ =404; }
  location /.well-known/pki-validation { try_files $uri $uri/ =404; }
  return 301 /index.php$request_uri;
 }

 location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
 location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }

 location ~ \.php(?:$|/) {
  rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /index.php$request_uri;
  fastcgi_split_path_info ^(.+?\.php)(/.*)$;
  set $path_info $fastcgi_path_info;
  try_files $fastcgi_script_name =404;
  include fastcgi_params;
  fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
  fastcgi_param PATH_INFO $path_info;
  fastcgi_param HTTPS on;
  fastcgi_param modHeadersAvailable true;
  fastcgi_param front_controller_active true;
  fastcgi_pass php-handler;
  fastcgi_intercept_errors on;
  fastcgi_request_buffering off;
  fastcgi_max_temp_file_size 0;
 }

 location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|map)$ {
  try_files $uri /index.php$request_uri;
  add_header Cache-Control "public, max-age=15778463, $asset_immutable";
  access_log off;

  location ~ \.wasm$ {
   default_type application/wasm;
  }
 }

 location ~ \.woff2?$ {
  try_files $uri /index.php$request_uri;
  expires 7d;
  access_log off;
 }

 location /remote {
  return 301 /remote.php$request_uri;
 }

 location / {
  try_files $uri $uri/ /index.php$request_uri;
 }
}
EOF

 # populate template here
 sed -i "
  /\${PHP_FPM_SOCKET_PATH}/   { s##${PHP_FPM_SOCKET_PATH}#; }
  /\${DOMAIN}/                { s##${DOMAIN}#; }
  /\${NEXTCLOUD_ROOT_PATH}/   { s##${NEXTCLOUD_ROOT_PATH}#; }
 " "${VHOST_CONF_PATH}"
 popd # from sites-enabled
 openssl req -x509 -newkey rsa:2048 -nodes -days $(expr '(' $(date -d 2999/01/01 +%s) - $(date +%s) + 86399 ')' / 86400) -subj "/" -keyout nginx.key -out nginx.crt
 popd # from /etc/nginx
 nginx -t
 systemctl enable nginx
 systemctl start nginx
}

prepare_nextcloud() {
 local DW_TMP
 DW_TMP="$(mktemp -d)"
 mkdir -p "${NEXTCLOUD_ROOT_PATH}"
 pushd "${NEXTCLOUD_ROOT_PATH}"
 install -d -m 0755 -o www-data -g www-data www
 install -d -m 0755 -o www-data tmp
 mkdir -p log/www
 pushd "${DW_TMP}"
 curl https://download.nextcloud.com/server/releases/latest.zip -o latest.zip
 unzip -DD -qq latest.zip
 rsync -au --remove-source-files --delete ./nextcloud/ "${NEXTCLOUD_ROOT_PATH}/www/"
 popd # from DW_TMP
 rm -rf "${DW_TMP}"
 # hack how to work with php8.2. Please remove it!
 sed -i 's/>= 80200/>= 80300/' www/lib/versioncheck.php
 chown -R www-data:www-data www
 su -s /bin/sh -c "php -f www/occ maintenance:install -n \
  --data-dir='${NEXTCLOUD_ROOT_PATH}/www/data' \
  --database='mysql' \
  --database-host='localhost' \
  --database-name='${NEXTCLOUD_DB_NAME}' \
  --database-user='${NEXTCLOUD_DB_USER}' \
  --database-pass='${NEXTCLOUD_DB_PASSWORD}' \
  --admin-user='${NEXTCLOUD_ADMIN_USER}' \
  --admin-pass='${NEXTCLOUD_ADMIN_PASSWORD}'" \
 www-data
 su -s /bin/sh -c 'php -f www/occ background:cron' www-data
 su -s /bin/sh -c "php -f www/occ config:system:set trusted_domains 0 --value='${DOMAIN}'" www-data
 pushd www/config
 # remove ending ); of php array
 su -s /bin/sh -c 'head -n -1 config.php > tmp.cfg.php' www-data
 cat << EOF >> 'tmp.cfg.php'
  'dbtableprefix' => 'oc_',
  'default_phone_region' => 'CZ',
  'mail_smtpmode' => 'smtp',
  'mail_smtpsecure' => 'ssl',
  'mail_sendmailmode' => 'smtp',
  'mail_from_address' => '${MAIL_FROM_ADDRESS}',
  'mail_domain' => '${MAIL_SENDER_DOMAIN}',
  'mail_smtphost' => '${MAIL_SMTP_HOST}',
  'mail_smtpport' => '465',
  'updater.release.channel' => 'stable',
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'session_lifetime' => 86400,
  'session_keepalive' => true,
  'filesystem_check_changes' => 1,
  'filelocking.enabled' => true,
EOF

if [[ $MAIL_SMTP_AUTH_ENABLED -eq 1 ]]; then
  cat << EOF >> 'tmp.cfg.php'
  'mail_smtpname' => '${MAIL_SMTP_USER}',
  'mail_smtppassword' => '${MAIL_SMTP_PASSWORD}',
  'mail_smtpauth' => 1,
EOF
 else
  echo "'mail_smtpauth' => 0," >> tmp.cfg.php
 fi
 echo ");" >> tmp.cfg.php
 mv tmp.cfg.php config.php
 popd
 popd
}

install_2fa_mail_plugin() {
 local DW_TMP
 DW_TMP="$(mktemp -d)"
 pushd "${DW_TMP}"

 curl -LJO https://github.com/nursoda/twofactor_email/releases/download/2.7.1/twofactor_email.tar.gz
 tar xzf twofactor_email.tar.gz

 rsync -au --remove-source-files --delete ./twofactor_email "${NEXTCLOUD_ROOT_PATH}/www/apps/"
 popd # DW_TMP
 rm -rf "${DW_TMP}"

 pushd "${NEXTCLOUD_ROOT_PATH}/www/apps/twofactor_email/appinfo/"
 # hack for php 8.2
 sed -i '/<php/ { /max-version=\".*\"/ { s//max-version=\"8.2\"/ } }' info.xml
 popd # twofactor_email

 pushd "${NEXTCLOUD_ROOT_PATH}"
 su -s /bin/sh -c "php --define apc.enable_cli=1 -f www/occ app:enable twofactor_email" www-data
 popd
}

install_nextcloud_plugins() {
 install_2fa_mail_plugin
}


set_systemd_timer() {
 pushd /etc/systemd/system/
 cat << EOF > ./nextcloudcron.service
[Unit]
Description=Nextcloud cron.php job

[Service]
User=www-data
ExecStart=/usr/bin/php --define apc.enable_cli=1 -f ${NEXTCLOUD_ROOT_PATH}/www/cron.php
KillMode=process
EOF
 
 cat << EOF > nextcloudcron.timer
[Unit]
Description=Run Nextcloud cron.php every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=nextcloudcron.service

[Install]
WantedBy=timers.target
EOF

 systemctl daemon-reload
 systemctl enable --now nextcloudcron.timer
 popd
}

# main start
ask_all
declare -r PHP_FPM_SOCKET_PATH="/var/run/php/php${PHP_VERSION}-fpm.sock"
set -e
set -x
prepare_system
prepare_db
prepare_nextcloud
install_nextcloud_plugins
set_php_fpm
set_https_certs
set_nginx
set_systemd_timer
