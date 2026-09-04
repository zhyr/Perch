#!/bin/bash
# 卸载 RecordTree
set -euo pipefail
pkill -x RecordTree 2>/dev/null || true
rm -rf "/Applications/RecordTree.app" "$HOME/Applications/RecordTree.app" 2>/dev/null || true
echo "RecordTree app removed."
echo "数据目录（如需删除请自行确认）: ~/Documents/RecordTree"
