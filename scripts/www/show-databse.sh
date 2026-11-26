#!/bin/bash

# Nạp hàm từ mysql_utils.sh trong cùng thư mục
source /var/www/ham-sh-mysql/mysql_utils.sh

# Câu lệnh MySQL để hiển thị danh sách các database
sql_command="SHOW DATABASES;"

# Gọi hàm check_mysql_connection với câu lệnh MySQL
check_mysql_connection "$sql_command"
result=$?

# Kiểm tra kết quả kết nối
if [ $result -eq 1 ]; then
    echo "da thuc thi xong"	    
else
    echo "Hàm trả về: Kết nối thất bại (0)"
fi
