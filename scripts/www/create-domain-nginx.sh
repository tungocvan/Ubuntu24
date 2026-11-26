#!/bin/bash

# ===============================
# Script: create-domain-nginx.sh
# Mục đích:
#   - Tạo hoặc xóa file cấu hình Nginx cho Laravel domain.
# Cách dùng:
#   ✅ Tạo domain:
#      ./create-domain-nginx.sh <ten_project>
#      VD: ./create-domain-nginx.sh inafo
#
#   ❌ Xóa domain:
#      ./create-domain-nginx.sh <ten_project> --delete
#      VD: ./create-domain-nginx.sh inafo --delete
#
# Kết quả:
#   /etc/nginx/sites-available/inafo.laravel.tk
#   /etc/nginx/sites-enabled/inafo.laravel.tk (symlink)
# ===============================

param1="$1"
action="$2"

if [ -z "$param1" ]; then
  echo "❌ Vui lòng nhập tên project. Ví dụ:"
  echo "   ./create-domain-nginx.sh inafo"
  exit 1
fi

TEMPLATE="/etc/nginx/sites-available/domain.tk"
NEW_FILE="/etc/nginx/sites-available/${param1}.laravel.tk"
SYMLINK="/etc/nginx/sites-enabled/${param1}.laravel.tk"

# ===============================
# XỬ LÝ XÓA DOMAIN (--delete)
# ===============================
if [ "$action" == "--delete" ]; then
  echo "🗑️  Đang xóa domain: ${param1}.laravel.tk ..."

  # Xóa file cấu hình
  if [ -f "$NEW_FILE" ]; then
    rm -f "$NEW_FILE"
    echo "✅ Đã xóa file: $NEW_FILE"
  else
    echo "⚠️  Không tìm thấy file: $NEW_FILE"
  fi

  # Xóa symlink
  if [ -L "$SYMLINK" ]; then
    rm -f "$SYMLINK"
    echo "✅ Đã xóa symlink: $SYMLINK"
  fi

  # Reload Nginx
  nginx -t && systemctl reload nginx
  echo "♻️  Nginx đã reload."
  exit 0
fi

# ===============================
# TẠO DOMAIN MỚI
# ===============================

# Kiểm tra file mẫu
if [ ! -f "$TEMPLATE" ]; then
  echo "❌ Không tìm thấy file mẫu: $TEMPLATE"
  exit 1
fi

# Sao chép file mẫu
cp "$TEMPLATE" "$NEW_FILE" || { echo "❌ Không thể sao chép file mẫu"; exit 1; }

# Thay thế chuỗi "domain" trong nội dung bằng tên tham số
sed -i.bak "s/domain/${param1}/g" "$NEW_FILE"

# Tạo symlink trong sites-enabled
if [ ! -f "$SYMLINK" ]; then
  ln -s "$NEW_FILE" "$SYMLINK"
  echo "🔗 Đã tạo symlink: $SYMLINK"
fi

# Kiểm tra & reload nginx
nginx -t
if [ $? -eq 0 ]; then
  systemctl reload nginx
  echo "✅ Đã tạo domain thành công: https://${param1}.laravel.tk"
else
  echo "❌ Lỗi cấu hình Nginx. Kiểm tra lại file: ${NEW_FILE}"
fi
