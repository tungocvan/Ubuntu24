#!/bin/bash

PROJECT="$1"
DOMAIN="${PROJECT}.laravel.tk"
APP_URL="https://$DOMAIN"
GIT_PATH=" git@github.com:tungocvan/laravel-basic.git $PROJECT"
### ============================
### 1. Check input
### ============================
if [ -z "$PROJECT" ]; then
    echo "❌ Vui lòng nhập tên project. Ví dụ: ./setup_project.sh inafo"
    exit 1
fi

### ============================
### 2. Check directory
### ============================
if [[ "$(pwd)" != "/var/www"* ]]; then
    echo "❌ Script phải được chạy trong /var/www"
    exit 1
fi


### ============================
### 3. Load DB config
### ============================
if [ ! -f "db.inc" ]; then
    echo "❌ Không tìm thấy file db.inc"
    exit 1
fi

source db.inc

if [[ -z "$username" || -z "$password" || -z "$hostname" ]]; then
    echo "❌ File db.inc thiếu thông tin (username/password/hostname)."
    exit 1
fi


### ============================
### 4. Create database
### ============================
DB_NAME="db_${PROJECT}"

echo "🛢️  Kiểm tra database $DB_NAME ..."

if mysql -u"$username" -p"$password" -h"$hostname" \
    --execute="SHOW DATABASES LIKE '$DB_NAME'" | grep -q "$DB_NAME"; then
    echo "⚠️  Database $DB_NAME đã tồn tại. Bỏ qua bước tạo."
else
    echo "🛠️  Tạo database $DB_NAME ..."
    mysql -u"$username" -p"$password" -h"$hostname" \
        --execute="CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" \
        || { echo "❌ Không thể tạo database!"; exit 1; }
    echo "✅ Database $DB_NAME đã tạo thành công."
fi


### ============================
### 5. Create project folder
### ============================
echo "📁 Tạo thư mục: $PROJECT ..."
mkdir -p "$PROJECT" || { echo "❌ Không thể tạo thư mục"; exit 1; }


### ============================
### 6. Clone repo
### ============================
echo "⬇️  Clone source mẫu...$GIT_PATH"
git clone git@github.com:tungocvan/laravel-basic.git  "$PROJECT" \
    || { echo "❌ Clone thất bại"; exit 1; }

cd "$PROJECT" || exit 1


### ============================
### 7. Copy .env
### ============================
echo "⚙️  Tạo file .env ..."
cp .env.example .env




### ============================
### 8. Update .env
### ============================
echo "📝 Cập nhật file .env ..."

sed -i "s/^APP_NAME=.*/APP_NAME=${PROJECT}/" .env
sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env
sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
# Lay tai khoan DB tu /var/www/db.inc, khong hardcode credentials.
# Dung Python de xu ly an toan cac ky tu dac biet trong mat khau.
python3 - <<'PY'
from pathlib import Path
import os
import re

config = Path("/var/www/db.inc")
env_file = Path(".env")

values = {}
for line in config.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    values[key.strip()] = value.strip()

username = values.get("username", "")
password = values.get("password", "")
if not username or not password:
    raise SystemExit("[ERROR] db.inc thieu username hoac password.")

def dotenv_quote(value: str) -> str:
    # Laravel dotenv: bao ve spaces, #, $, dau nhay va backslash.
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'

content = env_file.read_text(encoding="utf-8")
for key, value in (("DB_USERNAME", username), ("DB_PASSWORD", password)):
    replacement = f"{key}={dotenv_quote(value)}"
    pattern = rf"(?m)^{key}=.*$"
    if re.search(pattern, content):
        content = re.sub(pattern, lambda _: replacement, content)
    else:
        content = content.rstrip("\n") + "\n" + replacement + "\n"

env_file.write_text(content, encoding="utf-8")
os.chmod(env_file, 0o600)
print("[SUCCESS] Da cap nhat DB_USERNAME va DB_PASSWORD tu /var/www/db.inc.")
PY


### ============================
### 9. Composer install
### ============================
echo "📦 Cài đặt Composer..."
composer update --no-interaction --prefer-dist


### ============================
### 10. Laravel migrate + seed
### ============================
echo "🚀 Chạy migrate & seed..."
php artisan key:generate
php artisan migrate:fresh --force
php artisan db:seed --force


### ============================
### 11. Optimize Laravel
### ============================
echo "🧹 Dọn dẹp cache..."
php artisan optimize:clear


### ============================
### 12. Install NPM
### ============================
echo "⚙️  Cài npm ..."
npm install
npm run build

 
### ============================
### 13. Fix Permissions
### ============================
echo "🔐 Phân quyền ..."
chown -R www-data:www-data "/var/www/$PROJECT"
php artisan storage:link

### ============================
### 14. Cấu hình Nginx
### ============================

TEMPLATE="/var/www/$PROJECT/domain.tk"
NEW_FILE="/etc/nginx/sites-available/$DOMAIN"
SYMLINK="/etc/nginx/sites-enabled/$DOMAIN"
echo "$TEMPLATE"
# Kiểm tra file mẫu
if [ ! -f "$TEMPLATE" ]; then
  echo "❌ Không tìm thấy file mẫu: $TEMPLATE"
  exit 1
fi
# Sao chép file mẫu
cp "$TEMPLATE" "$NEW_FILE" || { echo "❌ Không thể sao chép file mẫu"; exit 1; }

# Thay thế chuỗi "domain" trong nội dung bằng tên tham số
sed -i.bak "s/domain/${PROJECT}/g" "$NEW_FILE"

# Tạo symlink trong sites-enabled
if [ ! -f "$SYMLINK" ]; then
  ln -s "$NEW_FILE" "$SYMLINK"
  echo "🔗 Đã tạo symlink: $SYMLINK"
fi

# Kiểm tra & reload nginx
nginx -t
if [ $? -eq 0 ]; then
  systemctl reload nginx
  echo "✅ Đã tạo domain thành công: $APP_URL"
else
  echo "❌ Lỗi cấu hình Nginx. Kiểm tra lại file: ${NEW_FILE}"
fi

### ============================
### DONE
### ============================
echo "🎉 DONE!"
echo "➡️ Project: $PROJECT"
echo "➡️ URL: $APP_URL"
echo "➡️ Database: ${DB_NAME}"
