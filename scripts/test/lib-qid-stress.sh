# lib-qid-stress.sh — shared helpers for QID stress tests.
# Source this; do not execute. Mirrors idioms proven in
# test-qid8-ring-wrap-stress.sh.

# resolve_bdf <ctrl-node>  -> echoes 0xBBDD
resolve_bdf() {
    local ctrl_name pci bus slot func devfn
    ctrl_name="$(basename "$1")"
    pci="$(basename "$(readlink -f "/sys/class/nvme/$ctrl_name/device")")"
    bus="0x$(echo "$pci" | cut -d: -f2)"
    slot="$(echo "$pci" | cut -d: -f3 | cut -d. -f1)"
    func="$(echo "$pci" | cut -d. -f2)"
    devfn=$(( (0x$slot << 3) | func ))
    printf "0x%02x%02x" "$bus" "$devfn"
}

# lba_size <bdev> -> echoes bytes (default 512)
lba_size() {
    local lbads
    lbads="$(${NVME_CMD:-nvme} id-ns "$1" 2>/dev/null | grep -E '^lbaf' \
        | grep 'in use' | head -1 | sed -E 's/.*lbads:([0-9]+).*/\1/')"
    [ -z "$lbads" ] && lbads=9
    echo $(( 1 << lbads ))
}

# controller_reset_fresh <ctrl-name>  (resets + settles for fresh snapshot)
controller_reset_fresh() {
    echo 1 > "/sys/class/nvme/$1/reset_controller" 2>/dev/null
    sleep 4
}

# dmesg_mark <marker-file>  -- stamp current last dmesg line (baseline)
dmesg_mark() {
    dmesg | tail -1 > "$1" 2>/dev/null || true
}

# dmesg_bad_since <marker-file> <qid>  -> prints bad lines since marker, empty if clean
dmesg_bad_since() {
    local marker qid src
    marker="$(cat "$1" 2>/dev/null)"
    qid="$2"
    if [ -n "$marker" ]; then
        src="$(dmesg | awk -v m="$marker" 'f{print} $0==m{f=1}')"
    else
        # No baseline captured -> scan everything (err toward catching
        # problems rather than silently passing).
        src="$(dmesg)"
    fi
    printf '%s\n' "$src" \
        | grep -iE "QID $qid timeout|reset controller|Oops|kernel BUG|Invalid SQE|invalid queue|general protection" \
        || true
}

# prewrap_ring <cpu> <bdev> <half_wraps> <queue_len> <lba_size>
# Drives an ODD number of half-ring-wraps of direct reads so cq_phase
# flips off the device-fresh state. half_wraps MUST be odd.
prewrap_ring() {
    local cpu="$1" bdev="$2" half="$3" qlen="$4" lbsz="$5"
    local cmds=$(( half * qlen / 2 ))
    taskset -c "$cpu" dd if="$bdev" of=/dev/null bs="$lbsz" \
        count="$cmds" iflag=direct >/dev/null 2>&1
}

# timed_io <op:write|read> <cpu> <bdev> <lba> <bytes> <datafile> <timeout_s>
# Echoes wall-clock latency (seconds, 2dp); returns nonzero on
# timeout/failure. NLB is zero-based (blocks-1).
timed_io() {
    local op="$1" cpu="$2" bdev="$3" lba="$4" bytes="$5" data="$6" to="$7"
    local lbsz blocks nlb t0 t1 rc
    lbsz="$(lba_size "$bdev")"
    blocks=$(( bytes / lbsz )); nlb=$(( blocks - 1 ))
    t0=$(date +%s.%N)
    if [ "$op" = write ]; then
        timeout "$to" taskset -c "$cpu" "${NVME_CMD:-nvme}" write "$bdev" \
            --start-block="$lba" --block-count="$nlb" --data-size="$bytes" \
            --data="$data" >/dev/null 2>&1
    else
        timeout "$to" taskset -c "$cpu" "${NVME_CMD:-nvme}" read "$bdev" \
            --start-block="$lba" --block-count="$nlb" --data-size="$bytes" \
            --data="$data" >/dev/null 2>&1
    fi
    rc=$?
    t1=$(date +%s.%N)
    awk "BEGIN{printf \"%.2f\", $t1-$t0}"
    return $rc
}
