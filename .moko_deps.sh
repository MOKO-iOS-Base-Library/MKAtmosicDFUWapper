#!/bin/zsh
# ============================================================
#  Moko 依赖自动更新脚本 (仓库内置版)
#  - git clone 下来就自带, Xcode build 时自动触发
#  - 优先用本机 ~/.moko/update_deps.py (revision 级更新)
#  - 否则降级: 子组件用 swift package update, 壳工程用 xcodebuild -resolve
#  - 永远 exit 0, 不阻塞 build
# ============================================================
# exit 0 先设好, 保证永远不阻塞 Xcode build
trap 'exit 0' EXIT

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
GLOBAL_SCRIPT="$HOME/Desktop/.moko/update_deps.py"
CACHE_FILE="$HOME/.moko_last_update"
CACHE_HOURS=24

# ---- 24h 缓存: 避免每次 build 都跑 ----
if [ -f "$CACHE_FILE" ]; then
    LAST=$(cat "$CACHE_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    DIFF=$(( (NOW - LAST) / 3600 ))
    if [ "$DIFF" -lt "$CACHE_HOURS" ]; then
        exit 0
    fi
fi
date +%s > "$CACHE_FILE" 2>/dev/null

cd "$REPO_ROOT" || exit 0

# ---- 1. 优先用全局 update_deps.py ----
if [ -f "$GLOBAL_SCRIPT" ]; then
    if [ -f "Package.swift" ]; then
        /usr/bin/python3 "$GLOBAL_SCRIPT" --libs-only --build-phase 2>/dev/null
    elif [ -d "*.xcodeproj" ] || find . -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null | head -1 | grep -q .; then
        /usr/bin/python3 "$GLOBAL_SCRIPT" --apps-only --build-phase 2>/dev/null
    else
        /usr/bin/python3 "$GLOBAL_SCRIPT" --build-phase 2>/dev/null
    fi
    exit 0
fi

# ---- 2. 降级: 子组件 (有 Package.swift) ----
if [ -f "Package.swift" ]; then
    /usr/bin/swift package update 2>/dev/null
    exit 0
fi

# ---- 3. 降级: 壳工程 (有 xcodeproj) ----
XC=$(find . -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null | head -1)
if [ -n "$XC" ]; then
    /usr/bin/xcodebuild -resolvePackageDependencies -project "$XC" 2>/dev/null
    exit 0
fi

exit 0
