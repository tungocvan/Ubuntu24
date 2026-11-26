#!/bin/bash
param1="$1"

# Kiểm tra xem tham số đã được cung cấp hay chưa
if [ -z "$param1" ]; then
  echo "Vui lòng nhập tên cơ sở dữ liệu cần sao lưu."
  exit 1
fi

source db.inc
if [[ -z "$username" || -z "$password" || -z "$hostname" ]]; then
        echo "Vui lòng kiểm tra file db.inc, một hoặc nhiều thông tin đang thiếu."
        return 0
fi

# Kiểm tra xem cơ sở dữ liệu có tồn tại không
if mysql -u"$username" -p"$password" -h"$hostname" --execute="SHOW DATABASES LIKE '$param1'" | grep -q "$param1"; then
  echo "Đang sao lưu cơ sở dữ liệu $param1 ..."
  mysqldump -u"$username" -p"$password" -h"$hostname" "$param1" > "$param1.sql"
else
  echo "Cơ sở dữ liệu $param1 không tồn tại."
  exit 1
fi
