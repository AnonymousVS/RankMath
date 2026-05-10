#!/bin/bash
###############################################################################
# connect-account.sh
# Bulk Connect Account — Rank Math SEO (across cPanel accounts)
# Version : 1.2.1
# Location: /usr/local/sbin/connect-account.sh
# Repo    : https://github.com/AnonymousVS/RankMath
# ─────────────────────────────────────────────────────────────────────────────
# CHANGELOG:
#   v1.2.1 | 2026-05-10 18:58 | Update repo URL: rankmath → RankMath
#           |                  |   (Pascal-Case ตาม pattern repo อื่นๆ)
#   v1.2.0 | 2026-05-10 18:47 | Add Mode 1/2 interactive menu
#           |                  |   Mode 1 = ทั้งเซิร์ฟเวอร์ (เหมือนเดิม)
#           |                  |   Mode 2 = เลือกเฉพาะบาง cPanel
#           |                  | Add Telegram notification
#           |                  | Add UI banner + color codes (menu/header/summary)
#           |                  | Add print_header(), get_all_cpanel_users()
#           |                  | Add send_telegram(), is_quit_keyword()
#           |                  | Add select_cpanel_accounts(), confirm_yn()
#           |                  | scan_wordpress() now accepts filter_users[]
#           |                  | Strict input validation:
#           |                  |   - ผิดแม้แต่ตัวเดียว → re-prompt ทั้งหมด
#           |                  |   - max retry 3 ครั้ง
#           |                  |   - พิมพ์ q / Q / quit / exit ออกได้ตลอด
#           |                  | Octal-safe input parsing (10#$sel)
#           |                  | Remove /home2-/home5 + /usr/home (เซิร์ฟเวอร์ใช้แค่ /home)
#   v1.1.7 | (legacy)         | Auto run all WordPress on server
###############################################################################

VERSION="1.2.1"

MAX_JOBS=10
WP_TIMEOUT=25
DEACT_TIMEOUT=8
MAX_RETRY=3

# ── Telegram (แก้ค่าตรงนี้) ────────────────────────────────────────────────
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN="8728146015:AAHEqYfqU8DOEc99BhPNci7HOFEMVGfiaeQ"
TELEGRAM_CHAT_ID="-5107218486"

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   WHITE='\033[1;37m'
BOLD='\033[1m';      DIM='\033[2m';        RESET='\033[0m'

###############################################################################
# โหลด credentials
# รองรับ 3 วิธี:
#   1. ส่ง config file path เป็น argument:  bash script.sh /path/to/conf
#   2. ใช้ env var:  RANKMATH_CONF=/path/to/conf bash script.sh
#   3. ใช้ default:  /root/.rankmath-connect.conf
###############################################################################
CONFIG_FILE="${1:-${RANKMATH_CONF:-/root/.rankmath-connect.conf}}"

# รองรับกรณีส่งเข้ามาเป็น /dev/fd/xx (pipe จาก bash <(...))
_TMP_CONF=""
if [[ "$CONFIG_FILE" == /dev/fd/* || "$CONFIG_FILE" == /proc/self/fd/* ]]; then
    _TMP_CONF=$(mktemp /tmp/rankmath-conf-XXXXXX)
    cat "$CONFIG_FILE" > "$_TMP_CONF"
    CONFIG_FILE="$_TMP_CONF"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}❌ ERROR:${RESET} ไม่พบ config file: $CONFIG_FILE"
    echo ""
    echo "วิธีใช้:"
    echo "  bash $0 /path/to/rankmath-connect.conf"
    echo "  RANKMATH_CONF=/path/to/conf bash $0"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

for _var in RM_USERNAME RM_EMAIL RM_API_KEY RM_PLAN RM_OLD_USERNAME RM_OLD_API_KEY; do
    if [[ -z "${!_var}" ]]; then
        echo -e "${RED}❌ ERROR:${RESET} config ขาด $_var"
        exit 1
    fi
done

###############################################################################
# Logging setup
###############################################################################
LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/rankmath-connect.log"
LOG_PASS="$LOG_DIR/rankmath-connect-pass.log"
LOG_FAIL="$LOG_DIR/rankmath-connect-fail.log"
LOG_ALREADY="$LOG_DIR/rankmath-connect-already.log"
LOG_OVERWRITE="$LOG_DIR/rankmath-connect-overwrite.log"
LOG_NOPLUGIN="$LOG_DIR/rankmath-connect-noplugin.log"

RESULT_DIR=$(mktemp -d /tmp/rankmath-XXXXXX)
export RESULT_DIR

###############################################################################
# Logging functions (atomic write)
###############################################################################
_write_log() {
    local file="$1" msg="$2" lock="${1}.lck"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    (
        flock -x 9
        echo "[$ts] $msg" >> "$file"
    ) 9>"$lock"
}

log_main()      { echo "$1"; _write_log "$LOG_FILE"      "$1"; }
log_pass()      { _write_log "$LOG_PASS"      "$1"; }
log_fail()      { _write_log "$LOG_FAIL"      "$1"; }
log_already()   { _write_log "$LOG_ALREADY"   "$1"; }
log_overwrite() { _write_log "$LOG_OVERWRITE" "$1"; }
log_noplugin()  { _write_log "$LOG_NOPLUGIN"  "$1"; }

log_init() {
    > "$LOG_FILE"; > "$LOG_PASS"; > "$LOG_FAIL"
    > "$LOG_ALREADY"; > "$LOG_OVERWRITE"; > "$LOG_NOPLUGIN"
}

###############################################################################
# Cleanup
###############################################################################
cleanup() {
    wait 2>/dev/null
    rm -rf "$RESULT_DIR"
    [[ -n "$_TMP_CONF" ]] && rm -f "$_TMP_CONF"
    find "$LOG_DIR" -name "rankmath-connect*.lck" -delete 2>/dev/null
}
trap cleanup EXIT INT TERM

###############################################################################
# Header
###############################################################################
print_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}Rank Math Bulk Connect  v${VERSION}${RESET}${BLUE}                              ║${RESET}"
    echo -e "${BLUE}║  ${DIM}Server: $(hostname -s)  |  Account: ${RM_EMAIL}${RESET}${BLUE}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

###############################################################################
# Pre-flight checks
###############################################################################
check_requirements() {
    WP_BIN=$(command -v wp 2>/dev/null)
    if [[ -z "$WP_BIN" ]]; then
        echo -e "${RED}❌ ERROR:${RESET} ไม่พบ WP-CLI — https://wp-cli.org"
        exit 1
    fi

    command -v flock &>/dev/null || {
        echo -e "${RED}❌ ERROR:${RESET} ไม่พบ flock (util-linux)"
        exit 1
    }

    [[ ! -f /etc/trueuserdomains ]] && {
        echo -e "${RED}❌ ERROR:${RESET} ไม่พบ /etc/trueuserdomains"
        exit 1
    }

    if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
        command -v curl &>/dev/null || {
            echo -e "${YELLOW}⚠️  WARN:${RESET} ไม่พบ curl — Telegram notification จะถูกข้าม"
            TELEGRAM_ENABLED=false
        }
    fi
}

###############################################################################
# Get All cPanel Users — จาก /etc/trueuserdomains
###############################################################################
get_all_cpanel_users() {
    local -n _out=$1
    _out=()
    [[ ! -f /etc/trueuserdomains ]] && return
    local -A _seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local u
        u=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$u" ]] && continue
        [[ "$u" == "root" || "$u" == "nobody" ]] && continue
        [[ -z "${_seen[$u]+x}" ]] && _seen["$u"]=1 && _out+=("$u")
    done < /etc/trueuserdomains
    mapfile -t _out < <(printf '%s\n' "${_out[@]}" | sort)
}

###############################################################################
# Telegram Notification
###############################################################################
send_telegram() {
    [[ "$TELEGRAM_ENABLED" != "true" ]] && return
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return

    local mode_label="$1"
    local total="$2"
    local pass="$3"
    local already="$4"
    local fail="$5"
    local noplugin="$6"
    local overwrite="$7"
    local elapsed="$8"
    local accounts_label="$9"

    local end_time
    end_time=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')
    local icon="✅"
    [[ $fail -gt 0 ]] && icon="⚠️"
    [[ $fail -eq $total && $total -gt 0 ]] && icon="❌"

    local msg
    msg=$(cat <<EOF
${icon} <b>Rank Math Bulk Connect</b>
🖥 Server : <code>$(hostname -s)</code>
🎛 Mode   : <b>${mode_label}</b>
👥 ${accounts_label}
📧 Account: <code>${RM_EMAIL}</code>
🕐 ${end_time}

├ Total WordPress : ${total}
├ ✅ Pass          : ${pass}  (overwrite ${overwrite})
├ ✔️ Already       : ${already}
├ ❌ Fail          : ${fail}
└ ⏭ No Plugin     : ${noplugin}

⏱ ใช้เวลา : $(( elapsed / 60 )) นาที $(( elapsed % 60 )) วินาที
📄 <code>${LOG_FILE}</code>
EOF
)
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="${msg}" \
        > /dev/null 2>&1
}

###############################################################################
# scan_wordpress — หา WordPress ทุกเว็บผ่าน /etc/trueuserdomains
# รองรับ filter_users[]:
#   - ถ้าว่าง: scan ทุก user
#   - ถ้ามีค่า: scan เฉพาะ user ที่อยู่ในรายการ
###############################################################################
scan_wordpress() {
    local filter_users=("$@")

    declare -A _SEEN
    DIRS=()

    _add_dir() {
        local d; d="$(dirname "$1")/"
        [[ -z "${_SEEN[$d]+_}" ]] && { _SEEN[$d]=1; DIRS+=("$d"); }
    }

    while IFS=' ' read -r _dom _usr _rest; do
        _usr="${_usr%:}"
        [[ -z "$_usr" ]] && continue

        # Filter ตาม filter_users (Mode 2)
        if [[ ${#filter_users[@]} -gt 0 ]]; then
            local match=0
            for u in "${filter_users[@]}"; do
                [[ "$u" == "$_usr" ]] && match=1 && break
            done
            [[ $match -eq 0 ]] && continue
        fi

        local _uhome
        _uhome=$(getent passwd "$_usr" 2>/dev/null | cut -d: -f6)
        [[ -d "$_uhome" ]] || continue

        while IFS= read -r -d '' f; do _add_dir "$f"; done \
            < <(find "$_uhome" -maxdepth 6 -name "wp-config.php" -print0 2>/dev/null)
    done < /etc/trueuserdomains
}

###############################################################################
# deactivateSite แบบ background (non-blocking)
###############################################################################
deactivate_bg() {
    local u="$1" k="$2" site="$3"
    curl -s -m "$DEACT_TIMEOUT" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$u\",\"api_key\":\"$k\",\"site_url\":\"$site\"}" \
        "https://rankmath.com/wp-json/rankmath/v1/deactivateSite" \
        &>/dev/null &
    disown
}

###############################################################################
# process_site — Inject Rank Math credentials
###############################################################################
process_site() {
    local dir="$1" idx="$2" total="$3"
    local SITE LABEL UNIQ STATUS EVAL_OUT

    SITE=$(echo "$dir" | sed 's|/home[0-9]*/\?||;s|/$||')
    LABEL="[$idx/$total] $SITE"
    UNIQ="${BASHPID}_${idx}"

    [[ -f "${dir}wp-config.php" ]] || return

    EVAL_OUT=$(timeout "$WP_TIMEOUT" \
        "$WP_BIN" --path="$dir" \
            --skip-themes \
            eval '
        // 1. ตรวจ Plugin
        $slug = null;
        foreach (["seo-by-rank-math/rank-math.php","rank-math-seo/rank-math.php"] as $f) {
            if (is_plugin_active($f)) { $slug = $f; break; }
        }
        if (!$slug) { echo "STATUS:NOPLUGIN"; return; }

        // 2. ตรวจ account ปัจจุบัน
        $reg = RankMath\Admin\Admin_Helper::get_registration_data();
        if ($reg && !empty($reg["api_key"])) {
            $cur = $reg["username"] ?? "";
            if ($cur === "'"$RM_USERNAME"'") {
                printf("STATUS:ALREADY\tUSER:%s\tPLAN:%s", $cur, $reg["plan"] ?? "?");
                return;
            }
            $old_key = ($cur === "'"$RM_OLD_USERNAME"'") ? "'"$RM_OLD_API_KEY"'" : ($reg["api_key"] ?? "");
            printf("STATUS:OVERWRITE\tOLD_USER:%s\tOLD_KEY:%s\t", $cur, $old_key);
            RankMath\Admin\Admin_Helper::get_registration_data(false);
            wp_cache_flush();
        }

        // 3. Inject
        $site_url = get_option("siteurl");
        RankMath\Admin\Admin_Helper::get_registration_data([
            "username"  => "'"$RM_USERNAME"'",
            "email"     => "'"$RM_EMAIL"'",
            "api_key"   => "'"$RM_API_KEY"'",
            "plan"      => "'"$RM_PLAN"'",
            "connected" => true,
            "site_url"  => $site_url,
        ]);

        // 4. Flush cache
        wp_cache_flush();
        wp_cache_delete("rank_math_connect_data", "options");
        if (class_exists("LiteSpeed\Purge"))            { LiteSpeed\Purge::purge_all(); }
        elseif (function_exists("litespeed_purge_all")) { litespeed_purge_all(); }

        // 5. Verify
        $v = RankMath\Admin\Admin_Helper::get_registration_data();
        $ok = ($v && ($v["api_key"] ?? "") === "'"$RM_API_KEY"'") ? "1" : "0";
        printf("STATUS:DONE\tSITE:%s\tSAVED:%s", $site_url, $ok);
    ' --allow-root 2>/dev/null)

    STATUS=$(echo "$EVAL_OUT" | grep -oP '(?<=STATUS:)\w+' | head -1)

    case "$STATUS" in
        ALREADY)
            local AU AP
            AU=$(echo "$EVAL_OUT" | grep -oP '(?<=USER:)[^\t]*')
            AP=$(echo "$EVAL_OUT" | grep -oP '(?<=PLAN:)[^\t]*')
            log_main "✔️  ALREADY: $LABEL | user=$AU"
            log_already "$SITE | user=$AU | plan=$AP"
            touch "${RESULT_DIR}/already_${UNIQ}"
            ;;

        OVERWRITE)
            local OLD_U OLD_K DU
            OLD_U=$(echo "$EVAL_OUT" | grep -oP '(?<=OLD_USER:)[^\t ]*')
            OLD_K=$(echo "$EVAL_OUT" | grep -oP '(?<=OLD_KEY:)[^\t ]*')
            DU=$(echo "$EVAL_OUT"    | grep -oP '(?<=SITE:)[^\t ]*')
            [[ -n "$OLD_U" && -n "$OLD_K" && -n "$DU" ]] && deactivate_bg "$OLD_U" "$OLD_K" "$DU"
            if echo "$EVAL_OUT" | grep -q "SAVED:1"; then
                timeout 15 "$WP_BIN" --path="$dir" cache flush --allow-root &>/dev/null &
                timeout 15 "$WP_BIN" --path="$dir" litespeed-purge all --allow-root &>/dev/null &
                log_main "🔄 OVERWRITE: $LABEL | $OLD_U → $RM_USERNAME | $DU"
                log_overwrite "$SITE | old=$OLD_U → new=$RM_USERNAME | site=$DU"
                touch "${RESULT_DIR}/pass_${UNIQ}"
            else
                log_main "❌ FAIL (overwrite): $LABEL | old=$OLD_U"
                log_fail "$SITE | overwrite fail | old=$OLD_U"
                touch "${RESULT_DIR}/fail_${UNIQ}"
            fi
            ;;

        DONE)
            local DU DS
            DU=$(echo "$EVAL_OUT" | grep -oP '(?<=SITE:)[^\t]*')
            DS=$(echo "$EVAL_OUT" | grep -oP '(?<=SAVED:)\d+')
            if [[ "$DS" == "1" ]]; then
                timeout 15 "$WP_BIN" --path="$dir" cache flush --allow-root &>/dev/null &
                timeout 15 "$WP_BIN" --path="$dir" litespeed-purge all --allow-root &>/dev/null &
                log_main "✅ PASS: $LABEL | $DU"
                log_pass "$SITE | site=$DU"
                touch "${RESULT_DIR}/pass_${UNIQ}"
            else
                log_main "❌ FAIL (verify): $LABEL"
                log_fail "$SITE | verify fail"
                touch "${RESULT_DIR}/fail_${UNIQ}"
            fi
            ;;

        NOPLUGIN)
            log_main "⏭  SKIP: $LABEL"
            log_noplugin "$SITE"
            touch "${RESULT_DIR}/noplugin_${UNIQ}"
            ;;

        *)
            local SHORT="${EVAL_OUT:0:120}"
            log_main "❌ FAIL (error): $LABEL | $SHORT"
            log_fail "$SITE | $SHORT"
            touch "${RESULT_DIR}/fail_${UNIQ}"
            ;;
    esac
}

export -f process_site deactivate_bg _write_log log_main log_pass log_fail log_already log_overwrite log_noplugin
export LOG_FILE LOG_PASS LOG_FAIL LOG_ALREADY LOG_OVERWRITE LOG_NOPLUGIN LOG_DIR
export RESULT_DIR WP_TIMEOUT DEACT_TIMEOUT WP_BIN
export RM_USERNAME RM_EMAIL RM_API_KEY RM_PLAN RM_OLD_USERNAME RM_OLD_API_KEY

###############################################################################
# is_quit_keyword — รับ q / Q / quit / exit
###############################################################################
is_quit_keyword() {
    local input="${1,,}"
    case "$input" in
        q|quit|exit) return 0 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# select_cpanel_accounts — Mode 2 prompt loop with strict validation
###############################################################################
select_cpanel_accounts() {
    local -n _list=$1
    local total=${#_list[@]}

    SELECTED_USERS=()

    local attempt=0
    while (( attempt < MAX_RETRY )); do
        (( attempt++ ))

        echo ""
        printf "${WHITE}เลือก [1-%d] (q = ออก): ${RESET}" "$total"
        read -r RAW_SEL

        local trimmed
        trimmed=$(echo "$RAW_SEL" | xargs)
        if is_quit_keyword "$trimmed"; then
            echo -e "${YELLOW}ยกเลิกการทำงาน${RESET}"
            exit 0
        fi

        if [[ -z "$trimmed" ]]; then
            echo -e "  ${RED}[ERROR]${RESET} ไม่ได้เลือกหมายเลขใด"
            if (( attempt < MAX_RETRY )); then
                echo -e "  ${YELLOW}กรุณาพิมพ์ใหม่ทั้งหมดอีกครั้ง (ครั้งที่ ${attempt}/${MAX_RETRY})${RESET}"
                continue
            else
                echo -e "  ${RED}เกินจำนวนครั้งที่กำหนด (${MAX_RETRY} ครั้ง) — ยกเลิกการทำงาน${RESET}"
                exit 1
            fi
        fi

        local -a errors=()
        local -a candidates=()
        for sel in $(echo "$RAW_SEL" | tr ',' ' '); do
            if [[ "$sel" =~ ^[0-9]+$ ]]; then
                # ใช้ 10# prefix กัน octal interpretation (08, 09 → error)
                local idx=$(( 10#$sel - 1 ))
                if (( idx >= 0 && idx < total )); then
                    candidates+=("${_list[$idx]}")
                else
                    errors+=("หมายเลข ${sel} ไม่มีใน list")
                fi
            else
                errors+=("'${sel}' ไม่ใช่หมายเลข")
            fi
        done

        if [[ ${#errors[@]} -gt 0 ]]; then
            for e in "${errors[@]}"; do
                echo -e "  ${RED}[ERROR]${RESET} $e"
            done
            if (( attempt < MAX_RETRY )); then
                echo -e "  ${YELLOW}กรุณาพิมพ์ใหม่ทั้งหมดอีกครั้ง (ครั้งที่ ${attempt}/${MAX_RETRY})${RESET}"
                continue
            else
                echo -e "  ${RED}เกินจำนวนครั้งที่กำหนด (${MAX_RETRY} ครั้ง) — ยกเลิกการทำงาน${RESET}"
                exit 1
            fi
        fi

        if [[ ${#candidates[@]} -eq 0 ]]; then
            echo -e "  ${RED}[ERROR]${RESET} ไม่ได้เลือกหมายเลขใด"
            if (( attempt < MAX_RETRY )); then
                echo -e "  ${YELLOW}กรุณาพิมพ์ใหม่ทั้งหมดอีกครั้ง (ครั้งที่ ${attempt}/${MAX_RETRY})${RESET}"
                continue
            else
                echo -e "  ${RED}เกินจำนวนครั้งที่กำหนด (${MAX_RETRY} ครั้ง) — ยกเลิกการทำงาน${RESET}"
                exit 1
            fi
        fi

        mapfile -t SELECTED_USERS < <(printf '%s\n' "${candidates[@]}" | sort -u)
        return 0
    done
}

###############################################################################
# confirm_yn — รับ y/N + รองรับ q/quit/exit
###############################################################################
confirm_yn() {
    local prompt="$1"
    printf "%b" "$prompt"
    read -r ANS
    if is_quit_keyword "$ANS"; then
        echo -e "${YELLOW}ยกเลิกการทำงาน${RESET}"
        exit 0
    fi
    [[ "${ANS,,}" == "y" ]]
}

###############################################################################
# run_setup — main work logic (รับ filter_users[] เพื่อจำกัด scope)
###############################################################################
run_setup() {
    local mode_label="$1"
    shift
    local filter_users=("$@")

    log_init
    local START_TIME
    START_TIME=$(date +%s)

    log_main "======================================"
    log_main " BULK RANK MATH CONNECT v${VERSION}"
    log_main " Mode      : ${mode_label}"
    log_main " เริ่มเวลา : $(date '+%Y-%m-%d %H:%M:%S')"
    log_main " Account   : $RM_EMAIL | plan=$RM_PLAN"
    log_main " Jobs      : $MAX_JOBS"
    if [[ ${#filter_users[@]} -gt 0 ]]; then
        log_main " Filter    : ${filter_users[*]}"
    else
        log_main " Filter    : ALL"
    fi
    log_main "======================================"

    # ── Scan WordPress ──
    scan_wordpress "${filter_users[@]}"
    local TOTAL=${#DIRS[@]}

    # accounts label สำหรับ Telegram
    local ACCOUNTS_LABEL ALL_USERS_TMP=()
    get_all_cpanel_users ALL_USERS_TMP
    local SERVER_TOTAL=${#ALL_USERS_TMP[@]}
    if [[ ${#filter_users[@]} -gt 0 ]]; then
        ACCOUNTS_LABEL="cPanel Accounts: ${#filter_users[@]} accounts (เลือกจาก ${SERVER_TOTAL})"
    else
        ACCOUNTS_LABEL="cPanel Accounts: ${SERVER_TOTAL} accounts"
    fi

    log_main "พบ WordPress : $TOTAL เว็บ"
    log_main "======================================"

    if [[ $TOTAL -eq 0 ]]; then
        log_main "⚠️  ไม่พบ WordPress เลย หยุดการทำงาน"
        local END_TIME ELAPSED
        END_TIME=$(date +%s)
        ELAPSED=$(( END_TIME - START_TIME ))
        send_telegram "$mode_label" 0 0 0 0 0 0 "$ELAPSED" "$ACCOUNTS_LABEL"
        return 0
    fi

    # ── Parallel runner ──
    local -a PIDS=()
    local COUNT=0
    for dir in "${DIRS[@]}"; do
        COUNT=$(( COUNT + 1 ))
        process_site "$dir" "$COUNT" "$TOTAL" &
        PIDS+=($!)
        while (( ${#PIDS[@]} >= MAX_JOBS )); do
            for i in "${!PIDS[@]}"; do
                if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
                    unset "PIDS[$i]"
                fi
            done
            PIDS=("${PIDS[@]}")
            (( ${#PIDS[@]} >= MAX_JOBS )) && sleep 0.2
        done
    done
    wait

    # ── สรุป ──
    local END_TIME ELAPSED
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))

    local C_PASS C_FAIL C_ALREADY C_NOPLUGIN C_OVERWRITE
    C_PASS=$(     find "$RESULT_DIR" -name "pass_*"     2>/dev/null | wc -l)
    C_FAIL=$(     find "$RESULT_DIR" -name "fail_*"     2>/dev/null | wc -l)
    C_ALREADY=$(  find "$RESULT_DIR" -name "already_*"  2>/dev/null | wc -l)
    C_NOPLUGIN=$( find "$RESULT_DIR" -name "noplugin_*" 2>/dev/null | wc -l)
    C_OVERWRITE=$(grep -c "" "$LOG_OVERWRITE" 2>/dev/null || echo 0)

    log_main "======================================"
    log_main " สรุปผลรวม"
    log_main " รวมทั้งหมด              : $TOTAL เว็บ"
    log_main " ✅ Pass/Overwrite       : $C_PASS เว็บ (รวม overwrite $C_OVERWRITE เว็บ)"
    log_main " ✔️  Already              : $C_ALREADY เว็บ (ข้ามแล้ว)"
    log_main " ❌ Fail                  : $C_FAIL เว็บ"
    log_main " ⏭  No Plugin             : $C_NOPLUGIN เว็บ"
    log_main " เวลาที่ใช้               : $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
    log_main "======================================"
    log_main " ✅ Pass      : $LOG_PASS"
    log_main " ✔️  Already   : $LOG_ALREADY"
    log_main " 🔄 Overwrite : $LOG_OVERWRITE"
    log_main " ❌ Fail      : $LOG_FAIL"
    log_main " ⏭  Skip      : $LOG_NOPLUGIN"
    log_main "======================================"

    # ── Summary banner (with colors) ──
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}SUMMARY${RESET}${BLUE}                                                      ║${RESET}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf  "${BLUE}║${RESET}  Total WordPress    : ${WHITE}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$TOTAL"      ""
    printf  "${BLUE}║${RESET}  ${GREEN}Pass${RESET}               : ${GREEN}%-4d${RESET}  ${DIM}(overwrite ${C_OVERWRITE})${RESET}%-18s${BLUE}║${RESET}\n" "$C_PASS" ""
    printf  "${BLUE}║${RESET}  ${CYAN}Already${RESET}            : ${CYAN}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$C_ALREADY"  ""
    printf  "${BLUE}║${RESET}  ${RED}Fail${RESET}               : ${RED}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$C_FAIL"     ""
    printf  "${BLUE}║${RESET}  ${YELLOW}No Plugin${RESET}          : ${YELLOW}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$C_NOPLUGIN" ""
    echo -e "${BLUE}║${RESET}  ${DIM}Log : ${LOG_FILE}${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"

    # ── Telegram ──
    send_telegram "$mode_label" "$TOTAL" "$C_PASS" "$C_ALREADY" "$C_FAIL" "$C_NOPLUGIN" "$C_OVERWRITE" "$ELAPSED" "$ACCOUNTS_LABEL"
}

###############################################################################
# MAIN
###############################################################################
check_requirements
print_header

# ─── Menu ───────────────────────────────────────────────────────────────────
echo -e "${WHITE}${BOLD}เลือกโหมดการทำงาน:${RESET}"
echo ""
echo -e "  ${CYAN}1.${RESET}  Connect Account ${WHITE}ทุกเว็บ${RESET} ในเซิร์ฟเวอร์นี้ทั้งหมด"
echo -e "  ${CYAN}2.${RESET}  เลือก Connect Account เฉพาะบาง ${WHITE}cPanel${RESET} ในเซิร์ฟเวอร์นี้"
echo ""
echo -e "  ${DIM}(พิมพ์ q / quit / exit เพื่อออกได้ตลอด)${RESET}"
echo ""
printf "${WHITE}กรุณาเลือก [1-2]: ${RESET}"
read -r MODE

trimmed_mode=$(echo "$MODE" | xargs)
if is_quit_keyword "$trimmed_mode"; then
    echo -e "${YELLOW}ยกเลิกการทำงาน${RESET}"
    exit 0
fi

declare -a ALL_CPANEL_USERS=()
get_all_cpanel_users ALL_CPANEL_USERS

if [[ ${#ALL_CPANEL_USERS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} ไม่พบ cPanel accounts ใน /etc/trueuserdomains"
    exit 1
fi

case "$MODE" in
    1)
        # ───── Mode 1: All cPanel ─────
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 1 ]  Connect Account — ทุก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ (${#ALL_CPANEL_USERS[@]} accounts):${RESET}"
        echo ""
        for u in "${ALL_CPANEL_USERS[@]}"; do
            echo -e "  ${GREEN}•${RESET}  $u"
        done
        echo ""
        echo -e "  ${DIM}(พิมพ์ q / quit / exit เพื่อออก)${RESET}"
        echo ""
        if confirm_yn "${YELLOW}ยืนยันการ Connect Account บนทุก cPanel ข้างบน? [y/N]: ${RESET}"; then
            print_header
            run_setup "Mode 1: ทั้งเซิร์ฟเวอร์"
        else
            echo -e "${RED}ยกเลิก${RESET}"
            exit 0
        fi
        ;;

    2)
        # ───── Mode 2: Select cPanel ─────
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 2 ]  เลือก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ (${#ALL_CPANEL_USERS[@]} accounts):${RESET}"
        echo ""
        for i in "${!ALL_CPANEL_USERS[@]}"; do
            printf "  ${CYAN}%3d.${RESET}  %s\n" "$(( i + 1 ))" "${ALL_CPANEL_USERS[$i]}"
        done
        echo ""
        echo -e "${YELLOW}เลือกหมายเลข (คั่นด้วย space หรือ comma)${RESET}"
        echo -e "${DIM}เช่น:  1 3 5   หรือ   1,3,5${RESET}"

        SELECTED_USERS=()
        select_cpanel_accounts ALL_CPANEL_USERS

        echo ""
        echo -e "${CYAN}cPanel ที่เลือก (${#SELECTED_USERS[@]} accounts):${RESET}"
        for u in "${SELECTED_USERS[@]}"; do
            echo -e "  ${GREEN}✔${RESET}  $u"
        done
        echo ""
        if confirm_yn "${YELLOW}ยืนยันการ Connect Account บน cPanel ข้างบน? [y/N]: ${RESET}"; then
            print_header
            run_setup "Mode 2: เลือกบาง cPanel" "${SELECTED_USERS[@]}"
        else
            echo -e "${RED}ยกเลิก${RESET}"
            exit 0
        fi
        ;;

    *)
        echo -e "${RED}[ERROR]${RESET} กรุณาเลือก 1 หรือ 2"
        exit 1
        ;;
esac
