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
    └── backup-system-config.sh
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
```

## Chính sách dữ liệu

Báo cáo cấu hình có thể chứa hostname, IP nội bộ/công cộng, username, tên service và thông tin hạ tầng. Chỉ lưu local, thư mục quyền 0700 và file 0600; không commit snapshot, backup hay file .env. Không đọc nội dung private keys, shadow, token hoặc file secrets. Hãy kiểm tra thủ công trước khi chia sẻ.

Script backup chỉ sao lưu các file cấu hình chọn lọc (không bao gồm SSH host keys, credentials); không phải full-system backup. Kiểm tra và thử restore trước khi sử dụng production.

## Yêu cầu

Ubuntu Server 24.04 LTS, Bash, coreutils. `collect-os-config.sh` và `backup-system-config.sh` yêu cầu root; các tiện ích không có sẽ được đánh dấu unavailable. Docker là tùy chọn.

## Kiểm tra

```bash
bash -n scripts/*.sh
# Nếu đã cài ShellCheck:
shellcheck scripts/*.sh
```

Không tự động cập nhật OS, thay đổi firewall, xóa volume/container hay restart service.
