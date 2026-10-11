#!/usr/bin/env bash
# Module: General Preparation

clone_repo() {
    if [[ ! -d $BUILD_DIR ]]; then
        echo "克隆仓库: $REPO_URL 分支: $REPO_BRANCH"
        if ! git clone --depth 1 -b $REPO_BRANCH $REPO_URL $BUILD_DIR; then
            echo "错误：克隆仓库 $REPO_URL 失败" >&2
            exit 1
        fi
    fi
}

clean_up() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        echo "Build directory $BUILD_DIR does not exist"
        return
    fi
    cd "$BUILD_DIR"
    if [[ -f ".config" ]]; then
        \rm -f ".config"
    fi
    if [[ -d "tmp" ]]; then
        \rm -rf "tmp"
    fi
    if [[ -d "logs" ]]; then
        # L1: glob 必须在引号外展开 —— 旧写法 rm -rf "logs/*" 把星号当字面量，
        # 永远删不掉任何东西（rm -f 静默失败）。无匹配时字面量被 -f 吞掉，安全。
        \rm -rf logs/*
    fi
    if [[ -d "feeds" ]]; then
        ./scripts/feeds clean
    fi
    mkdir -p "tmp"
    echo "1" >"tmp/.build"
}

reset_feeds_conf() {
    git reset --hard origin/$REPO_BRANCH
    git clean -f -d
    git pull
    if [[ $COMMIT_HASH != "none" ]]; then
        # L2: depth=1 克隆本地没有任意历史 commit，直接 checkout 必失败。
        # 先按 SHA 单独 fetch，失败则给出明确错误（而不是 checkout 的含糊报错）。
        if ! git fetch --depth 1 origin "$COMMIT_HASH" || ! git checkout --quiet "$COMMIT_HASH"; then
            echo "错误：无法获取/检出 COMMIT_HASH=$COMMIT_HASH（depth-1 克隆需按 SHA 单独 fetch；该 commit 可能已被上游 GC 或不可达）" >&2
            exit 1
        fi
    fi
}
