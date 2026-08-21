#!/bin/bash
# GitZ vs Git Benchmark Suite
# Compares performance on real-world operations

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GITZ="${1:-./zig-out/bin/gitz}"
GIT="git"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       GitZ vs Git Performance Benchmark      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# --- Helper functions ---
time_cmd() {
    local start end ms
    start=$(date +%s%N)
    "$@" > /dev/null 2>&1
    local rc=$?
    end=$(date +%s%N)
    ms=$(( (end - start) / 1000000 ))
    echo "$ms"
}

compare() {
    local op="$1" git_ms="$2" gitz_ms="$3"

    if [ "$gitz_ms" -eq 0 ]; then
        echo -e "  ${GREEN}✓ $op: gitz <1ms vs git ${git_ms}ms (instant)${NC}"
        return
    fi

    if [ "$gitz_ms" -lt "$git_ms" ]; then
        local faster=$(( (git_ms - gitz_ms) * 100 / (git_ms > 0 ? git_ms : 1) ))
        echo -e "  ${GREEN}✓ $op: gitz ${gitz_ms}ms vs git ${git_ms}ms (${faster}% faster)${NC}"
    elif [ "$gitz_ms" -gt "$git_ms" ]; then
        local slower=$(( (gitz_ms - git_ms) * 100 / (git_ms > 0 ? git_ms : 1) ))
        echo -e "  ${YELLOW}△ $op: gitz ${gitz_ms}ms vs git ${git_ms}ms (${slower}% slower)${NC}"
    else
        echo -e "  ${CYAN}= $op: both ${gitz_ms}ms${NC}"
    fi
}

echo -e "${YELLOW}Test 1: Repository initialization${NC}"
mkdir -p "$TMPDIR/init_git" "$TMPDIR/init_gitz"
git_ms=$(time_cmd $GIT init "$TMPDIR/init_git" --quiet)
gitz_ms=$(time_cmd $GITZ init "$TMPDIR/init_gitz")
compare "init" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 2: Add 1000 small files${NC}"
mkdir -p "$TMPDIR/add_git/files" "$TMPDIR/add_gitz/files"
for i in $(seq 1 1000); do
    echo "file content $i" > "$TMPDIR/add_git/files/file_$i.txt"
    echo "file content $i" > "$TMPDIR/add_gitz/files/file_$i.txt"
done
cd "$TMPDIR/add_git" && $GIT init --quiet > /dev/null 2>&1
git_ms=$(time_cmd $GIT -C "$TMPDIR/add_git" add .)
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/add_gitz" add .)
compare "add 1000 files" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 3: Commit${NC}"
git_ms=$(time_cmd $GIT -C "$TMPDIR/add_git" commit -m "test commit" --quiet)
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/add_gitz" commit -m "test commit")
compare "commit" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 4: Status (clean repo)${NC}"
git_ms=$(time_cmd $GIT -C "$TMPDIR/add_git" status)
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/add_gitz" status)
compare "status" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 5: Log${NC}"
git_ms=$(time_cmd $GIT -C "$TMPDIR/add_git" log --oneline)
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/add_gitz" log --oneline)
compare "log" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 6: Diff (100 modified files)${NC}"
for i in $(seq 1 100); do
    echo "modified $i" >> "$TMPDIR/add_git/files/file_$i.txt"
    echo "modified $i" >> "$TMPDIR/add_gitz/files/file_$i.txt"
done
git_ms=$(time_cmd $GIT -C "$TMPDIR/add_git" diff)
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/add_gitz" diff)
compare "diff 100 files" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 7: Branch operations${NC}"
git_ms=$(time_cmd bash -c "cd $TMPDIR/add_git && $GIT branch test-br && $GIT checkout test-br > /dev/null 2>&1 && $GIT checkout main > /dev/null 2>&1 && $GIT branch -d test-br")
gitz_ms=$(time_cmd bash -c "cd $TMPDIR/add_gitz && $GITZ branch test-br && $GITZ switch test-br && $GITZ switch main && $GITZ branch -d test-br")
compare "branch ops" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 8: Status with 10000 files${NC}"
mkdir -p "$TMPDIR/big_git/files" "$TMPDIR/big_gitz/files"
for i in $(seq 1 10000); do
    echo "content $i" > "$TMPDIR/big_git/files/file_$i.txt"
    echo "content $i" > "$TMPDIR/big_gitz/files/file_$i.txt"
done
cd "$TMPDIR/big_git" && $GIT init --quiet > /dev/null 2>&1 && $GIT add . > /dev/null 2>&1 && $GIT commit -m "init" --quiet > /dev/null 2>&1
cd "$TMPDIR/big_gitz" && $GITZ init > /dev/null 2>&1 && $GITZ add . > /dev/null 2>&1 && $GITZ commit -m "init" > /dev/null 2>&1
git_ms=$(time_cmd $GIT -C "$TMPDIR/big_git" status)
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/big_gitz" status)
compare "status 10000 files" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 9: Merge${NC}"
mkdir -p "$TMPDIR/merge_git" "$TMPDIR/merge_gitz"
cd "$TMPDIR/merge_git"
$GIT init --quiet > /dev/null 2>&1 && echo "a" > file.txt && $GIT add . > /dev/null 2>&1 && $GIT commit -m "base" --quiet > /dev/null 2>&1
$GIT checkout -b feature > /dev/null 2>&1 && echo "b" > feature.txt && $GIT add . > /dev/null 2>&1 && $GIT commit -m "feature" --quiet > /dev/null 2>&1
$GIT checkout main > /dev/null 2>&1
git_ms=$(time_cmd $GIT -C "$TMPDIR/merge_git" merge feature --no-edit --quiet)

cd "$TMPDIR/merge_gitz"
$GITZ init > /dev/null 2>&1 && echo "a" > file.txt && $GITZ add . > /dev/null 2>&1 && $GITZ commit -m "base" > /dev/null 2>&1
$GITZ branch feature > /dev/null 2>&1 && $GITZ switch feature > /dev/null 2>&1 && echo "b" > feature.txt && $GITZ add . > /dev/null 2>&1 && $GITZ commit -m "feature" > /dev/null 2>&1
$GITZ switch main > /dev/null 2>&1
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/merge_gitz" merge feature)
compare "merge" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 10: GC (10000 files)${NC}"
git_ms=$(time_cmd $GIT -C "$TMPDIR/big_git" gc)
gitz_ms=$(time_cmd $GITZ -C "$TMPDIR/big_gitz" gc)
compare "gc" "$git_ms" "$gitz_ms"
echo ""

echo -e "${YELLOW}Test 11: Clone from GitHub${NC}"
mkdir -p "$TMPDIR/clone_test"
cd "$TMPDIR/clone_test"
git_ms=$(time_cmd $GIT clone --quiet git@github.com:jesusalcaladev/orbit.git git_orbit 2>/dev/null)
rm -rf git_orbit
gitz_ms=$(time_cmd $GITZ clone git@github.com:jesusalcaladev/orbit.git gitz_orbit 2>/dev/null)
rm -rf gitz_orbit
compare "clone from GitHub" "$git_ms" "$gitz_ms"
echo ""

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Benchmark Complete               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Key advantages of gitz:${NC}"
echo -e "  • DAG-aware packfiles → sequential reads = cache hits"
echo -e "  • mmap zero-copy → OS page cache"
echo -e "  • Thread pool → parallel status/add/diff"
echo -e "  • Streaming pack → process while downloading"
echo ""
