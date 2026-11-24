#!/bin/bash
# Script an toàn để pull code từ remote mà không bị kẹt
# Nó sẽ backup thay đổi local thành patch trước khi reset

set -e

BRANCH="main"
BACKUP_DIR="./git-backups"

# Tạo thư mục backup nếu chưa có
mkdir -p "$BACKUP_DIR"

# Tạo tên file backup kèm timestamp
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
PATCH_FILE="$BACKUP_DIR/backup-$TIMESTAMP.patch"

echo "🔍 Kiểm tra thay đổi local..."
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "📦 Phát hiện thay đổi local → tạo backup: $PATCH_FILE"
    git diff > "$PATCH_FILE"
else
    echo "✅ Không có thay đổi local."
fi

echo "⬇️  Fetching remote..."
git fetch --all

echo "🧹 Reset về origin/$BRANCH..."
git reset --hard origin/$BRANCH

echo "⬇️  Pull code mới nhất..."
git pull origin $BRANCH

echo "🎉 Hoàn tất! Code đã được đồng bộ với remote."
if [ -f "$PATCH_FILE" ]; then
    echo "📂 Backup thay đổi local lưu tại: $PATCH_FILE"
    echo "👉 Nếu muốn áp lại, dùng: git apply $PATCH_FILE"
fi
