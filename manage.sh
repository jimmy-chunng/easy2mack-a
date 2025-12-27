#!/bin/bash

# ====================================================
# NXM v5.1: 格式修复与逻辑清洗版
# 修复: 解决 Copy/Paste 导致的隐藏字符和语法报错
# ====================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}>>> 正在修复 NXM 工具脚本 (v5.1)...${NC}"

# 重新写入 nxm 管理工具 (移除所有复杂缩进，防止格式错误)
cat > /usr/local/bin/nxm << 'SCRIPT_EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# --- 数据库管理 ---
function add_db() {
    echo -e "${GREEN}=== 创建新数据库 ===${NC}"
    read -p "请输入数据库名 (例如 blog_db): " DBNAME
    read -p "请输入用户名 (例如 blog_user): " DBUSER
    read -p "请输入密码: " DBPASS

    # 修复语法: 使用更兼容的判断写法
    if [ -z "$DBNAME" ] || [ -z "$DBUSER" ] || [ -z "$DBPASS" ]; then
        echo "❌ 信息不能为空"; exit 1
    fi

    # 创建数据库
    mysql -e "CREATE DATABASE ${DBNAME};"
    mysql -e "CREATE USER '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 数据库创建成功!${NC}"
        echo "DB Name: $DBNAME"
        echo "DB User: $DBUSER"
        echo "DB Pass: $DBPASS"
    else
        echo -e "${RED}❌ 创建失败，请检查 MariaDB 服务状态。${NC}"
    fi
}

# --- 网站管理 ---
function add_vhost() {
    echo -e "${GREEN}=== 添加新网站 ===${NC}"
    echo "1. Xray 分流模式 (推荐): 复用 443，需泛域名证书"
    echo "2. 独立 SSL 模式: 独立证书 (端口 8443)"
    read -p "请选择模式 [1/2]: " MODE

    read -p "请输入域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then echo "❌ 域名不能为空"; exit 1; fi

    WEB_ROOT="/var/www/$DOMAIN"
    mkdir -p $WEB_ROOT
    echo "<?php phpinfo(); ?>" > $WEB_ROOT/phpinfo.php
    
    # 写入数据库连接测试脚本
    cat > $WEB_ROOT/dbtest.php <<EOF
<?php
\$servername = "localhost";
\$username = "你的数据库用户名";
\$password = "你的数据库密码";
\$conn = new mysqli(\$servername, \$username, \$password);
if (\$conn->connect_error) { die("连接失败: " . \$conn->connect_error); }
echo "✅ 数据库连接成功!";
?>
EOF

    chown -R www-data:www-data $WEB_ROOT
    chmod -R 755 $WEB_ROOT

    # 获取 PHP 环境
    PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
    PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

    # 模式 1: 分流
    if [[ "$MODE" == "1" ]]; then
        # 确保模板文件存在
        if [ ! -f /etc/nginx/nxm_internal_listen ]; then
            echo "listen 127.0.0.1:31302 http2 proxy_protocol;" > /etc/nginx/nxm_internal_listen
        fi
        INTERNAL_LISTEN=$(cat /etc/nginx/nxm_internal_listen)

        cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
server {
    $INTERNAL_LISTEN
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTPS on;
    }
    location / { try_files \$uri \$uri/ /index.php?\$args; }
}
EOF
    fi

    # 模式 2: 独立 SSL
    if [[ "$MODE" == "2" ]]; then
        read -p "请输入 Cloudflare API Token: " CF_TOKEN
        export CF_Token="$CF_TOKEN"
        
        /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --server zerossl
        SSL_DIR="/etc/nginx/ssl/$DOMAIN"
        mkdir -p $SSL_DIR
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
            --key-file $SSL_DIR/private.key \
            --fullchain-file $SSL_DIR/fullchain.cer \
            --reloadcmd "systemctl reload nginx"

        cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host:8443\$request_uri;
}
server {
    listen 8443 ssl http2;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;
    ssl_certificate $SSL_DIR/fullchain.cer;
    ssl_certificate_key $SSL_DIR/private.key;
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location / { try_files \$uri \$uri/ /index.php?\$args; }
}
EOF
    fi

    nginx -t && systemctl reload nginx
    echo -e "${GREEN}🎉 部署成功!${NC}"
    echo "PHP测试: https://$DOMAIN/phpinfo.php"
    echo "DB测试 : https://$DOMAIN/dbtest.php"
}

case "$1" in
    "vhost") [ "$2" == "add" ] && add_vhost ;;
    "db") [ "$2" == "add" ] && add_db ;;
    "fix") systemctl restart php*-fpm nginx mariadb; echo "修复完成" ;;
    *) echo "Usage: nxm vhost add | nxm db add | nxm fix" ;;
esac
SCRIPT_EOF

chmod +x /usr/local/bin/nxm

echo -e "${GREEN}✅ NXM v5.1 修复完成！${NC}"
echo "请再次尝试运行: nxm vhost add"
