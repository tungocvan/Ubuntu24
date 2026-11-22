# Ubuntu24 — Ubuntu Server 24.04 LTS DevOps Toolkit

Bộ công cụ Bash quản trị Ubuntu Server 24.04 LTS, ưu tiên an toàn, kiểm tra trước khi thao tác và không xóa dữ liệu.

## Cấu trúc

```text
Ubuntu24/
├── .gitignore
├── README.md
├── .env.example
└── scripts/
    ├── collect-os-config.sh
    ├── status.sh
    ├── check-docker.sh
    ├── backup-system-config.sh
    └── export-os-report.sh
```

## Bắt đầu

```bash
git clone https://github.com/tungocvan/Ubuntu24.git
cd Ubuntu24
bash -n scripts/*.sh
chmod +x scripts/*.sh
./scripts/status.sh
./scripts/check-docker.sh
sudo ./scripts/collect-os-config.sh
```

Báo cáo OS mặc định lưu trong `/var/local/ubuntu24/inventory/`. Mỗi lần chạy tạo thư mục snapshot mới; không ghi đè snapshot trước. Xem vị trí snapshot trong output của script.

```bash
sudo ./scripts/collect-os-config.sh --help
sudo ./scripts/collect-os-config.sh --output-dir /var/local/ubuntu24/inventory
sudo ./scripts/backup-system-config.sh
sudo bash scripts/export-os-report.sh --latest
sudo bash scripts/export-os-report.sh --snapshot 20261122T033707Z_000
```

Bản xuất mặc định lưu trong `exports/` ở thư mục dự án, được `.gitignore` loại trừ. File mới có tên duy nhất, không ghi đè. Khi chạy với sudo, file mới trong thư mục exports mặc định thuộc người gọi sudo, quyền 0600. Có thể đổi thư mục bằng `--output-dir /duong/dan/tuyet/doi`. Chỉ chia sẻ sau khi rà soát thông tin nhạy cảm.

## Chính sách dữ liệu

Báo cáo cấu hình có thể chứa hostname, IP nội bộ/công cộng, username, tên service và thông tin hạ tầng. Chỉ lưu local, thư mục quyền 0700 và file 0600; không commit snapshot, backup hay file .env. Không đọc nội dung private keys, shadow, token hoặc file secrets. Hãy kiểm tra thủ công trước khi chia sẻ.

Script backup chỉ sao lưu các file cấu hình chọn lọc (không bao gồm SSH host keys, credentials); không phải full-system backup. Kiểm tra và thử restore trước khi sử dụng production.

## Yêu cầu

Ubuntu 24.04 LTS hoặc 26.04 LTS (các bản Ubuntu khác: best-effort), Bash, coreutils. `collect-os-config.sh` và `backup-system-config.sh` yêu cầu root; các tiện ích không có sẽ được đánh dấu unavailable. Docker là tùy chọn.

## Kiểm tra

```bash
bash -n scripts/*.sh
# Nếu đã cài ShellCheck:
shellcheck scripts/*.sh
```

Không tự động cập nhật OS, thay đổi firewall, xóa volume/container hay restart service.

## Menu quản trị User & Group

```bash
sudo bash scripts/menu.sh
```

Menu cho phép liệt kê user/group, đổi mật khẩu (kể cả root), tạo user với home directory, thêm vào supplementary group có sẵn, và tạo group. Các thao tác thay đổi cần xác nhận `YES`. Mật khẩu nhập qua `passwd` tương tác; không lưu vào logs. Không thay đổi cấu hình SSH hoặc tự động cấp sudo. Chỉ chạy trên máy chủ tin cậy và rà soát trước khi tạo tài khoản.

## Manage Database (Ubuntu Native, MariaDB/MySQL)

Menu chính: `2) Manage Database`. Giai đoạn đầu chỉ có thao tác đọc: thử kết nối, thông tin server, danh sách database/table, dung lượng và processlist.

```bash
cd ~/projects/github/tungocvan/Ubuntu24
cp -n db.inc.example db.inc
chmod 600 db.inc
# Chỉnh sửa db.inc bằng trình soạn thảo local, không gửi mật khẩu lên GitHub.
sudo bash scripts/menu.sh
```

Cấu hình `db.inc` gồm `username`, `password`, `hostname`, `port`. File được `.gitignore` loại trừ. Mật khẩu không được truyền qua command line; client nhận cấu hình từ file tạm quyền 0600, xóa khi kết thúc lệnh. Kết nối dùng TCP, không cần tài khoản database có quyền quản trị. Các truy vấn sẽ chỉ trả về dữ liệu mà tài khoản database được cấp quyền xem. Chưa có chức năng backup, restore hoặc tạo/xóa database.

## Create Database User

Trong Manage Database, chọn 1) Connect Database, sau đó 8) Create Database User. Nhập username, host (mặc định localhost), mật khẩu hai lần và xác nhận YES. Lệnh CREATE USER chạy qua stdin của MySQL/MariaDB client; không đưa mật khẩu vào argv, log hoặc Git. Tài khoản kết nối từ db.inc cần quyền CREATE USER. User mới không được cấp quyền database tự động; cấp quyền theo nguyên tắc least privilege bằng thao tác quản trị riêng.

## Grant Database Privileges

Trong Manage Database, Connect Database trước rồi chọn 12) Grant Database Privileges. Nhập user, host và database đã tồn tại, chọn một trong bốn mức READ ONLY / READ-WRITE / DEVELOPER / FULL DATABASE, sau đó xác nhận YES. Chức năng chỉ thêm quyền trên database được chọn, không thu hồi quyền cũ, không cấp quyền toàn cục và không cho phép chọn database hệ thống. Cần quyền GRANT OPTION phù hợp trên database đích. Không dùng cho tài khoản ứng dụng quyền FULL DATABASE nếu không cần thiết.
