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

## Inspect and revoke database user privileges

Manage Database: 13) Show Database User Grants runs SHOW GRANTS for a validated existing account; 14) Revoke Database Privileges shows existing grants, requires a database name, offers SELECT / READ-WRITE / DEVELOPER / ALL PRIVILEGES on that database, and requires typing REVOKE. It does not delete user, database, or data. Revocation can interrupt applications and requires suitable GRANT OPTION. REVOKE ALL PRIVILEGES ON db.* does not necessarily revoke GRANT OPTION; inspect SHOW GRANTS and revoke that option separately if applicable. Privileges inherited from global grants or roles are not removed by database-scoped revocation.

## Database connection setup and login privileges

Manage Database option 15 configures hostname, port, username and a hidden password. The new credentials are tested over TCP before saving; type `SAVE` to write `db.inc`. Existing configuration is backed up to a private `.db.inc.backup.*` file (contains credentials) and the new file is mode 600. On connection failure, choose retry, configure, or cancel. On successful connection, the menu displays `USER()`, `CURRENT_USER()` and `SHOW GRANTS FOR CURRENT_USER()`. This is the server's grant output, not an inferred effective privilege summary. Review and securely retire credential backups when no longer needed.


## WireGuard VPN for remote MariaDB (option A)

The main menu now includes `3) Manage WireGuard VPN` (status, setup server, add client). The VPN uses split tunneling: client traffic to `10.77.0.1/32` enters WireGuard; ordinary Internet traffic remains on the client's normal connection. This setup does **not** open MariaDB TCP/3306 on the public interface, change MariaDB, configure UFW, enable forwarding, or modify SSH.

Prerequisites: Ubuntu Server with root access; server reachable by a public IPv4/DNS and inbound UDP 51820. If the server is behind a home router, forward **UDP 51820 only** to the server's LAN address. If behind CGNAT without a public endpoint, use a VPS relay or a mesh VPN rather than attempting port forwarding. Take a VM snapshot or backup before changing networking.

```bash
cd ~/projects/github/tungocvan/Ubuntu24
bash -n scripts/menu.sh scripts/vpn/wireguard.sh scripts/vpn/mariadb-proxy.sh
sudo bash scripts/menu.sh
# 3) Manage WireGuard VPN -> 2) Setup Server
# Enter the server's PUBLIC IPv4 or DNS (not the client's address)
# 3) Manage WireGuard VPN -> 3) Add Client
```

Direct commands (interactive confirmation required):

```bash
sudo bash scripts/vpn/wireguard.sh setup vpn.example.com
sudo bash scripts/vpn/wireguard.sh add-client laptop
sudo bash scripts/vpn/wireguard.sh status
```

Client configuration is generated at `/var/lib/ubuntu24/wireguard/clients/laptop.conf` with permissions 0600. Transfer it through a secure channel to the laptop's WireGuard client; never commit it or paste it into a chat. Keep it outside the Git repository. Only create one profile per device. The server configuration lives at `/etc/wireguard/wg-ubuntu24.conf`; backups are created there when adding clients.

**Firewall:** after confirming the active SSH allow rule, allow WireGuard's UDP port on the server. For UFW, review `sudo ufw status numbered` before adding `sudo ufw allow 51820/udp comment 'WireGuard VPN'`. Do not enable/reset UFW blindly on a remote server. If the cloud provider has a security group, allow UDP 51820 there as well. Do not allow TCP 3306 on the public interface.

**MariaDB access:** WireGuard connectivity alone does not make a database bound to `127.0.0.1:3306` reachable from `10.77.0.1`. First verify `sudo ss -lntp | grep ':3306'` and `sudo wg show wg-ubuntu24`. A controlled next step is a VPN-interface-only TCP proxy bound to `10.77.0.1:3306` forwarding to `127.0.0.1:3306`, or an explicitly reviewed MariaDB listener/firewall change. **An optional VPN-only proxy is now available in the menu (option 4); it is not enabled automatically.** Do not switch MariaDB to `0.0.0.0` without separately auditing host firewall, Docker port exposure and network access.

For a database bound to loopback, select menu `3) Manage WireGuard VPN -> 4) Enable VPN-only MariaDB Proxy`. It requires active WireGuard and a MariaDB listener at `127.0.0.1:3306`, installs `socat` with confirmation, and enables a systemd service listening **only** on `10.77.0.1:3306`. Use menu option 5 to stop/disable the proxy (this interrupts active remote DB sessions). Review UFW: allow TCP/3306 on the WireGuard interface only if your firewall blocks it; do not open TCP/3306 publicly.\n\nWhen a VPN-only listener has been configured, connect from the laptop with `mariadb --host=10.77.0.1 --port=3306 --protocol=tcp --user=YOUR_DB_USER -p`. Use a dedicated least-privilege database user. If a local TCP proxy forwards to loopback, MariaDB sees the proxy's local address, not the laptop's WireGuard IP; check `SELECT USER(), CURRENT_USER();` before assigning `user@host` grants. Do not assume the earlier `Enable Remote Access for User` option is required for a local proxy.

**Diagnostics:** `sudo wg show wg-ubuntu24`, `sudo systemctl status wg-quick@wg-ubuntu24`, `sudo journalctl -u wg-quick@wg-ubuntu24 -n 50 --no-pager`, and on the client `ping 10.77.0.1`. WireGuard status can show peers even without a recent successful handshake; inspect `latest handshake` and data counters.

**Rollback:** stop and disable WireGuard only after confirming no other dependent services: `sudo systemctl disable --now wg-quick@wg-ubuntu24`. Configuration and client keys are retained; this does not remove firewall rules or router forwarding. For key compromise, rotate/revoke the affected peer; deleting a local profile alone does not revoke server access.
