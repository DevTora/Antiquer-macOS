#!/bin/bash

# Antiquer — macOS 文件/文件夹时间戳查看与修改工具
# TUI (交互菜单):
# - 查看: 树状统计 + 可选修复 (文件夹: 所有时间 → 1980; 文件: 仅访问时间 → 1980)
# - 修改: 文件夹: 所有时间 → 1980; 文件: 创建+修改 → 用户输入, 访问时间 → 1980
# CLI (命令行参数):
# - 查看: <路径> ; 修改: <路径> <日期> [时间] (创建+修改 → 用户输入, 访问时间 → 1980)
# - 选项修改: -b/--birth/-c/--create (创建) -m/--modify (修改) -a/--access (访问) -A/--all (修改所有时间)
# - 其他选项: -h/--help (帮助) -H/--hidden (含隐藏文件)
# 依赖: macOS 内置工具 / Xcode SetFile (修改创建日期)

# 检查运行平台: 仅支持 Darwin (macOS), 依赖系统级工具行为
[[ "$(uname -s)" == "Darwin" ]] || { echo "${COL_RED}错误:${COL_RESET} 此脚本仅支持 macOS"; exit 1; }

# 严格模式: 出错即停 (-e)、未定义变量报错 (-u)、管道中任一失败即失败 (-o pipefail)
set -euo pipefail

# ============ 全局变量 ============

# 临时目录（扫描统计文件存放处）
temp_dir=""
# SetFile 命令路径（无可跳过修改创建时间）
setfile=""
# 命令行模式（跳过确认，直接执行）
cli_mode=false
# 修改创建时间（需要 SetFile）
modify_btime=false
# 修改修改时间（touch -m）
modify_mtime=false
# 修改访问时间（touch -a）
modify_atime=false
# 无选项时使用默认时间：文件: 创建+修改 → 用户输入, 访问时间 → 1980; 文件夹: 所有时间 → 1980
default_times=false
# 显示 . 开头的隐藏文件
show_hidden=false

# ============ 常量 ============

# 交互输入回退默认值
readonly DEFAULT_DATE="1980-01-01"
readonly DEFAULT_TIME="00:00:00"
# SetFile 格式（12 小时 + AM/PM，本地时区，不支持指定时区）
readonly DEFAULT_SF="01/01/1980 12:00:00 AM"
# touch 格式（YYYYMMDDhhmm.SS，24 小时，本地时区，不支持指定时区）
readonly DEFAULT_TC="198001010000.00"
# 用户界面显示格式
readonly DEFAULT_DISPLAY="1980-01-01 00:00:00"
# 并行进程数上限
readonly MAX_PARALLEL=2
# 树状递归最大深度
readonly MAX_TREE_DEPTH=500
# 每批处理文件数
readonly BATCH_SIZE=100
# 文件数超过此值时触发警告确认
readonly MAX_FILES_WARN=10000
# 版本号
readonly VERSION="0.1"

# 彩色输出常量
COL_RED=$([[ -t 2 ]] && tput setaf 1 2>/dev/null || true); readonly COL_RED
COL_YELLOW=$([[ -t 2 ]] && tput setaf 3 2>/dev/null || true); readonly COL_YELLOW
COL_RESET=$([[ -t 2 ]] && tput sgr0 2>/dev/null || true); readonly COL_RESET

# ============ 中断 & 清理 ============

clean_temp() {
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir"
        temp_dir=""
    fi
}

trap clean_temp EXIT
trap 'echo ""; echo "操作已中断"; clean_temp; exit 130' INT

# ============ SetFile 依赖 ============

find_setfile() {
    if command -v SetFile &>/dev/null; then
        setfile="SetFile"
    elif [[ -x "/Developer/Tools/SetFile" ]]; then
        setfile="/Developer/Tools/SetFile"
    fi
}

check_setfile() {
    if [[ -z "$setfile" ]]; then
        echo "${COL_RED}错误:${COL_RESET} 需要 Xcode 命令行工具, 运行 xcode-select --install" >&2
        return 1
    fi
}

# ============ 通用工具 ============

trim() {
    local str="$1"
    str="${str#"${str%%[![:space:]]*}"}"
    str="${str%"${str##*[![:space:]]}"}"
    echo "$str"
}

clean_path() {
    local path="$1"
    path=$(printf '%s\n' "$path" | sed 's/\\\(.\)/\1/g')
    path="${path/#\~/$HOME}"
    trim "$path"
}

get_times() {
    local path="$1"
    stat -f "%SB|%Sm|%Sa" -t "%Y-%m-%d %H:%M:%S" "$path" 2>/dev/null || echo "${DEFAULT_DISPLAY}|${DEFAULT_DISPLAY}|${DEFAULT_DISPLAY}"
}

find_items() {
    local path="$1"
    local depth="${2:-}"
    local args=()
    args+=("-s")
    args+=("--" "$path")
    [[ -n "$depth" ]] && args+=("-maxdepth" "$depth" "-mindepth" "1")
    if [[ "$show_hidden" == "false" ]]; then
        args+=("(" "-name" ".*" "-prune" ")" "-o")
    fi
    args+=("-print0")
    find "${args[@]}"
}

# ============ 用户确认 ============

confirm_modify() {
    $cli_mode && return 0
    local reply
    read -erp "是否执行修改(y/N): " reply || return 1
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

abort() {
    local do_clean="${1:-false}"
    if $do_clean; then
        echo "已取消..."
        clean_temp
    else
        echo "操作已取消"
        echo ""
    fi
    return 0
}

# ============ 进度条 ============

show_progress() {
    local current=$1 total=$2 width=40
    if [[ $total -eq 0 ]]; then
        local bar
        printf -v bar '%*s' "$width" ''; bar=${bar// /=}
        printf "\r[%s] 100%%" "$bar"
        return 0
    fi
    local pct=$(( current * 100 / total ))
    local filled=$(( pct * width / 100 ))
    [[ $filled -gt $width ]] && filled=$width
    local bar
    if [[ $filled -gt 0 ]]; then
        printf -v bar '%*s' "$filled" ''; bar=${bar// /=}
    else
        bar=""
    fi
    printf "\r[%-${width}s] %d%%" "$bar" "$pct" >&2
}

finish_progress() {
    printf "\n" >&2
}

# ============ 并行执行工具 ============

# 并行执行: 每个失败输出一个 ".", 返回失败总数
# 注意: 2>/dev/null 会吞掉 xargs 自身的错误输出(如找不到命令), 调试时去掉
_par_run() {
    local max_parallel=$1 cmd=$2; shift 2
    local items=("$@")
    [[ ${#items[@]} -eq 0 ]] && { echo 0; return; }
    local dots
    dots=$(printf '%s\0' "${items[@]}" | xargs -0 -P "$max_parallel" sh -c "$cmd" _ 2>/dev/null)
    echo "${#dots}"
}

# shellcheck disable=SC2016
par_touch_both_default() {
    _par_run "$MAX_PARALLEL" 'for f; do touch -t "'"$DEFAULT_TC"'" -- "$f" >/dev/null 2>&1 || printf "."; done' "$@"
}

# shellcheck disable=SC2016
par_touch_access_default() {
    _par_run "$MAX_PARALLEL" 'for f; do touch -a -t "'"$DEFAULT_TC"'" -- "$f" >/dev/null 2>&1 || printf "."; done' "$@"
}

# shellcheck disable=SC2016
par_setfile_create_default() {
    _par_run "$MAX_PARALLEL" 'for f; do '"$setfile"' -d "'"$DEFAULT_SF"'" "$f" >/dev/null 2>&1 || printf "."; done' "$@"
}

# ============ 批处理文件夹 ============

# 文件夹始终重置为 DEFAULT(1980-01-01), 不用用户指定的日期。
# 原因: 文件夹是容器, 其时间戳对 Finder 排序有影响, 统一重置避免不一致。
batch_reset_dirs_default() {
    local total=$1; shift
    [[ $total -eq 0 ]] && { echo 0; return 0; }
    local items=("$@")
    local i batch fail=0
    echo "" >&2
    echo "正在处理文件夹…" >&2
    for ((i=0; i<total; i+=BATCH_SIZE)); do
        batch=("${items[@]:i:BATCH_SIZE}")
        fail=$((fail + $(par_touch_both_default "${batch[@]}")))
        if [[ -n "$setfile" ]]; then
            fail=$((fail + $(par_setfile_create_default "${batch[@]}")))
        fi
        show_progress "$((i + ${#batch[@]}))" "$total"
    done
    finish_progress
    echo "文件夹处理完成!" >&2
    echo "$fail"
}

# ============ 日期工具 ============

resolve_target_datetime() {
    local input_date="${1:-}"
    local input_time="${2:-}"
    local interactive=false

    [[ -z "$input_date" && -z "$input_time" ]] && interactive=true

    while true; do
        if $interactive; then
            echo >&2 ""
            [[ -z "$input_date" ]] && { read -erp "目标日期 (默认${DEFAULT_DATE}): " input_date || return 1; }
            [[ -z "$input_time" ]] && { read -erp "目标时间 (默认${DEFAULT_TIME}): " input_time || return 1; }
        fi

        input_date=$(trim "${input_date:-$DEFAULT_DATE}")
        input_time=$(trim "${input_time:-$DEFAULT_TIME}")

        if [[ "$input_date" =~ ^[0-9]{1,4}-[0-9]{1,2}-[0-9]{1,2}$ ]]; then
            local y m d
            IFS='-' read -r y m d <<< "$input_date"
            input_date=$(printf "%04d-%02d-%02d" "$y" "$((10#$m))" "$((10#$d))")
        fi
        if [[ "$input_time" =~ ^[0-9]{1,2}:[0-9]{1,2}:[0-9]{1,2}$ ]]; then
            local h min s
            IFS=':' read -r h min s <<< "$input_time"
            input_time=$(printf "%02d:%02d:%02d" "$((10#$h))" "$((10#$min))" "$((10#$s))")
        fi

        local combined="${input_date} ${input_time}"
        if [[ ! "$combined" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            echo >&2 "错误: 格式无效, 日期应使用YYYY-MM-DD, 时间应使用HH:MM:SS"
            $interactive && { input_date=""; input_time=""; continue; } || return 1
        fi

        local y_check="${combined:0:4}"
        if [[ $((10#$y_check)) -lt 1970 || $((10#$y_check)) -gt 2038 ]]; then
            echo >&2 "错误: SetFile 仅支持 1970-01-01 至 2038-01-18 范围内的日期"
            $interactive && { input_date=""; input_time=""; continue; } || return 1
        fi

        if ! date -jf "%Y-%m-%d %H:%M:%S" "$combined" >/dev/null 2>&1; then
            echo >&2 "错误: 无效的日期/时间(如2月30日等非法日期)"
            $interactive && { input_date=""; input_time=""; continue; } || return 1
        fi

        local year="${combined:0:4}"
        local month="${combined:5:2}"
        local day="${combined:8:2}"

        # SetFile 32-bit time_t 限制: 最大 2038-01-18
        if [[ $((10#$year)) -eq 2038 && ( $((10#$month)) -gt 1 || ( $((10#$month)) -eq 1 && $((10#$day)) -gt 18 ) ) ]]; then
            echo >&2 "错误: SetFile 仅支持 2038-01-18 之前的日期"
            $interactive && { input_date=""; input_time=""; continue; } || return 1
        fi
        local hour_24="${combined:11:2}"
        local min="${combined:14:2}"
        local sec="${combined:17:2}"

        local hour_12 ampm
        if [[ "$hour_24" == "00" || "$hour_24" == "12" ]]; then
            hour_12="12"
            [[ "$hour_24" == "00" ]] && ampm="AM" || ampm="PM"
        elif (( 10#$hour_24 > 12 )); then
            hour_12=$(printf "%02d" $((10#$hour_24 - 12)))
            ampm="PM"
        else
            hour_12="$hour_24"
            ampm="AM"
        fi

        echo "${month}/${day}/${year} ${hour_12}:${min}:${sec} ${ampm}|${year}${month}${day}${hour_24}${min}.${sec}|${year}-${month}-${day} ${hour_24}:${min}:${sec}"
        return 0
    done
}

resolve_target_or_abort() {
    local date="$1" time="$2"
    if [[ -n "$date" ]]; then
        resolve_target_datetime "$date" "$time"
    else
        resolve_target_datetime
    fi
}

# ============ 查看模式 ============

show_default_stats() {
    local dir_default_count=$1 file_default_count=$2

    if [[ $dir_default_count -eq 0 && $file_default_count -eq 0 ]]; then
        echo "统计时间: 所有项均为非默认值"
        return 0
    fi

    local stats_file="$temp_dir/stats"
    local temp_count="$temp_dir/tcount"
    local example_file="$temp_dir/example"

    [[ -f "$stats_file" ]] && sort "$stats_file" | uniq -c | sort -rn > "$temp_count"
    [[ ! -f "$temp_count" ]] && touch "$temp_count"
    local combo_count
    combo_count=$(wc -l < "$temp_count" | tr -d ' ')
    echo "统计时间:"
    local group_index=0
    local count ctime mtime atime key example_file_name matched item_type line
    local max_display=20
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local tmp="${line#"${line%%[![:space:]]*}"}"
            count=$(( ${tmp%% *} ))
            key="${tmp#* }"
            ctime="${key%%|*}"; local rest="${key#*|}"
            mtime="${rest%%|*}"; atime="${rest#*|}"
            group_index=$((group_index + 1))
            if [[ $group_index -le $max_display || $combo_count -le $max_display ]]; then
                example_file_name=""
                item_type=""
                matched=$(grep -Fe "|$key|" "$example_file" | head -1)
                if [[ -n "$matched" ]]; then
                    local etype ename
                    IFS='|' read -r etype _ _ _ ename <<< "$matched"
                    item_type="$etype"
                    [[ "$item_type" == "dir" ]] && item_type="文件夹" || item_type="文件"
                    example_file_name="$ename"
                fi
                echo "  [$item_type] $example_file_name (共${count}个)"
                echo "    创建: $ctime"
                echo "    修改: $mtime"
                echo "    访问: $atime"
                echo ""
            fi
        fi
    done < "$temp_count"
    if [[ $combo_count -gt $max_display ]]; then
        echo "  ...(共${combo_count}种时间组合)"
        echo ""
    fi
    echo "  (其中${dir_default_count}个文件夹, ${file_default_count}个文件时间已为默认值)"
}

show_modify_list() {
    local non_default_file="$temp_dir/non_default"

    if [[ -s "$non_default_file" ]]; then
        local modify_dir_count=0 modify_file_count=0 type name
        echo ""
        echo "待修改($(wc -l < "$non_default_file" | tr -d ' ')个):"
        while IFS='|' read -r type ctime mtime atime name; do
            if [[ "$type" == "dir" ]]; then
                modify_dir_count=$((modify_dir_count + 1))
                echo "  [文件夹] $name"
                echo "    创建: $ctime → $DEFAULT_DISPLAY"
                echo "    修改: $mtime → $DEFAULT_DISPLAY"
                echo "    访问: $atime → $DEFAULT_DISPLAY"
            else
                modify_file_count=$((modify_file_count + 1))
                echo "  [文件] $name"
                echo "    创建: $ctime"
                echo "    修改: $mtime"
                echo "    访问: $atime → $DEFAULT_DISPLAY"
            fi
            echo ""
        done < "$non_default_file"
        echo "  (${modify_dir_count}个文件夹, ${modify_file_count}个文件)"
    fi
}

reset_non_defaults() {
    local non_default_file="$temp_dir/non_default"
    local non_default_paths="$temp_dir/nd_paths"
    check_setfile || { abort true; return 1; }
    local nd_dirs=() nd_files=() nd_path
    while IFS= read -r -d '' nd_path; do
        if [[ -d "$nd_path" ]]; then
            nd_dirs+=("$nd_path")
        else
            nd_files+=("$nd_path")
        fi
    done < "$non_default_paths"
    local nd_dir_count=${#nd_dirs[@]} nd_file_count=${#nd_files[@]}
    if $cli_mode; then
        abort true
        return 0
    fi

    echo ""
    confirm_modify || { abort true; return 1; }

    local fail_count=0
    if [[ $nd_dir_count -gt 0 ]]; then
        local batch_fail; batch_fail=$(batch_reset_dirs_default "$nd_dir_count" "${nd_dirs[@]}")
        fail_count=$((fail_count + batch_fail))
    fi
    if [[ $nd_file_count -gt 0 ]]; then
        echo ""
        echo "正在修改文件…"
        local processed=0 batch i
        for ((i=0; i<nd_file_count; i+=BATCH_SIZE)); do
            batch=("${nd_files[@]:i:BATCH_SIZE}")
            fail_count=$((fail_count + $(par_touch_access_default "${batch[@]}")))
            processed=$((processed + ${#batch[@]}))
            show_progress "$processed" "$nd_file_count"
        done
        finish_progress
        echo "文件处理完成!"
    fi
    if [[ $fail_count -gt 0 ]]; then
        echo "${COL_YELLOW}警告:${COL_RESET} 有 $fail_count 个操作失败"
    fi
    echo ""
    if [[ $nd_dir_count -gt 0 ]]; then
        IFS='|' read -r ctime mtime atime < <(get_times "${nd_dirs[0]}")
        echo "文件夹示例(${nd_dir_count}个): $(basename "${nd_dirs[0]}")"
        echo "  创建: $ctime"
        echo "  修改: $mtime"
        echo "  访问: $atime"
    fi
    if [[ $nd_file_count -gt 0 ]]; then
        [[ $nd_dir_count -gt 0 ]] && echo ""
        IFS='|' read -r ctime mtime atime < <(get_times "${nd_files[0]}")
        echo "文件示例(${nd_file_count}个): $(basename "${nd_files[0]}")"
        echo "  创建: $ctime"
        echo "  修改: $mtime"
        echo "  访问: $atime"
    fi
}

# ============ 树状结构输出 ============

print_tree() {
    local path="$1"
    local prefix="$2"
    local is_last="$3"
    local is_root="$4"
    local depth="${5:-0}"
    local ctime mtime atime item

    if (( depth > MAX_TREE_DEPTH )); then
        echo "${prefix}...(目录过深, 已截断)"
        return 0
    fi

    local base
    base=$(basename "$path")

    local type="文件" suffix=""
    [[ -d "$path" ]] && { type="文件夹"; suffix="/"; }

    local time_prefix="│ "
    if [[ "$is_root" == "true" ]]; then
        echo "[${type}] ${base}${suffix}"
    elif [[ "$is_last" == "true" || "$is_last" == "1" ]]; then
        echo "${prefix}└── [${type}] ${base}${suffix}"
        time_prefix="${prefix}    "
    else
        echo "${prefix}├── [${type}] ${base}${suffix}"
        time_prefix="${prefix}│   "
    fi

    IFS='|' read -r ctime mtime atime < <(get_times "$path")
    echo "${time_prefix}创建: $ctime"
    echo "${time_prefix}修改: $mtime"
    echo "${time_prefix}访问: $atime"

    if [[ -d "$path" ]]; then
        local items=()
        while IFS= read -r -d '' item; do
            [[ -z "$item" ]] && continue
            items+=("$item")
        done < <(find_items "$path" 1)

        local total=${#items[@]}
        if [[ $total -eq 0 ]]; then
            [[ "$is_root" != "true" ]] && echo "${time_prefix}"
            return 0
        fi

        if [[ "$is_root" == "true" ]]; then
            echo "│"
        else
            echo "${time_prefix}│   "
        fi

        local file_limit=3 file_seen=0 shown=0 extra=0
        local children_prefix
        if [[ "$is_root" == "true" ]]; then
            children_prefix=""
    elif [[ "$is_last" == "true" || "$is_last" == "1" ]]; then
            children_prefix="${prefix}    "
        else
            children_prefix="${prefix}│   "
        fi

        local item
        for item in "${items[@]}"; do
            if [[ -f "$item" ]]; then
                if (( file_seen >= file_limit )); then
                    extra=$((extra + 1))
                    continue
                fi
                file_seen=$((file_seen + 1))
            fi
            shown=$((shown + 1))
            print_tree "$item" "$children_prefix" "$((shown == total - extra))" "false" $((depth + 1))
        done

        if [[ $extra -gt 0 ]]; then
            echo "${children_prefix}...(还有 ${extra} 项)"
            echo "${children_prefix}"
        fi
        return 0
    else
                echo "${time_prefix}"
    fi
}

# ============ 查看入口 ============

view_mode() {
    local raw_path="${1:-}"
    [[ -z "$raw_path" ]] && { echo ""; read -erp "目标路径: " raw_path || return 1; }
    local target_path
    target_path=$(clean_path "$raw_path")

    if [[ ! -e "$target_path" ]]; then
        echo "${COL_RED}错误:${COL_RESET} 路径不存在"
        return 1
    fi

    echo ""
    echo "正在扫描目录..."

    if [[ -f "$target_path" ]]; then
        local file_count=1 dir_count=0
        echo "扫描完成, 共${dir_count}个文件夹, ${file_count}个文件"
        echo ""
        echo "[文件] $(basename "$target_path")"

        IFS='|' read -r ctime mtime atime < <(get_times "$target_path")
        echo "  创建: $ctime"
        echo "  修改: $mtime"
        echo "  访问: $atime"
        echo ""
        return 0
    fi

    temp_dir=$(mktemp -d) || { echo "${COL_RED}错误:${COL_RESET} 无法创建临时目录"; return 1; }
    trap 'clean_temp' EXIT
    local stats_file="$temp_dir/stats"
    local example_file="$temp_dir/example"
    local non_default_file="$temp_dir/non_default"
    local non_default_paths="$temp_dir/nd_paths"
    local file_count=0 dir_count=0 stats_dir_count=0 stats_file_count=0
    local key item ctime mtime atime
    while IFS= read -r -d '' item; do
        if [[ -d "$item" ]]; then
            dir_count=$((dir_count + 1))
            IFS='|' read -r ctime mtime atime < <(get_times "$item")
            key="$ctime|$mtime|$atime"
            grep -sqFe "$key|" "$example_file" 2>/dev/null || echo "dir|$key|$(basename "$item")" >> "$example_file"
            # 文件夹: 重置所有时间
            if [[ "$ctime" != "$DEFAULT_DISPLAY" || "$mtime" != "$DEFAULT_DISPLAY" || "$atime" != "$DEFAULT_DISPLAY" ]]; then
                echo "dir|$ctime|$mtime|$atime|$(basename "$item")" >> "$non_default_file"
                printf '%s\0' "$item" >> "$non_default_paths"
            else
                stats_dir_count=$((stats_dir_count + 1))
                echo "$key" >> "$stats_file"
            fi
        elif [[ -f "$item" ]]; then
            file_count=$((file_count + 1))
            IFS='|' read -r ctime mtime atime < <(get_times "$item")
            key="$ctime|$mtime|$atime"
            grep -sqFe "$key|" "$example_file" 2>/dev/null || echo "file|$key|$(basename "$item")" >> "$example_file"
            # 文件: 只重置访问时间, 创建+修改保持原值
            if [[ "$atime" != "$DEFAULT_DISPLAY" ]]; then
                echo "file|$ctime|$mtime|$atime|$(basename "$item")" >> "$non_default_file"
                printf '%s\0' "$item" >> "$non_default_paths"
            else
                stats_file_count=$((stats_file_count + 1))
                echo "$key" >> "$stats_file"
            fi
        fi
    done < <(find_items "$target_path")

    echo "扫描完成, 共${dir_count}个文件夹, ${file_count}个文件"
    echo ""

    print_tree "$target_path" "" "true" "true"

    if [[ $dir_count -gt 0 || $file_count -gt 0 ]]; then
        show_default_stats "$stats_dir_count" "$stats_file_count"

        if ! $cli_mode; then
            show_modify_list

            if [[ -s "$non_default_paths" ]]; then
                reset_non_defaults || true
            fi
        fi

        clean_temp
        trap - EXIT
    fi
    echo ""
}

# ============ 修改模式 ============

# 文件夹始终重置到 DEFAULT(1980-01-01)，不使用用户指定时间。
# 原因：文件夹在 Finder 中按创建时间排序，统一回退到固定时间可避免混合显示错乱。
reset_dir_times() {
    local dir_count=$1; shift
    batch_reset_dirs_default "$dir_count" "$@"
}

# 修改文件项的时间戳。使用用户指定的 target_tc/target_sf。
# default_times=true:  同时修改 mtime+atime+btime, atime 固定回 DEFAULT
# default_times=false: 按 modify_{mtime,atime,btime} 开关选择性修改
apply_file_times() {
    local file_count=$1 target_tc=$2 target_sf=$3; shift 3
    local files=("$@")
    local fail=0

    echo "" >&2
    echo "正在修改文件…" >&2

    # shellcheck disable=SC2016
    local cmd_mtime='for f; do touch -m -t "'"$target_tc"'" -- "$f" >/dev/null 2>&1 || printf "."; done'
    # shellcheck disable=SC2016
    local cmd_atime='for f; do touch -a -t "'"$target_tc"'" -- "$f" >/dev/null 2>&1 || printf "."; done'
    # shellcheck disable=SC2016
    local cmd_btime='for f; do '"$setfile"' -d "'"$target_sf"'" "$f" >/dev/null 2>&1 || printf "."; done'

    local processed=0 batch i
    for ((i=0; i<file_count; i+=BATCH_SIZE)); do
        batch=("${files[@]:i:BATCH_SIZE}")
        if [[ "$default_times" == "true" ]]; then
            fail=$((fail + $(_par_run "$MAX_PARALLEL" "$cmd_mtime" "${batch[@]}")))
            fail=$((fail + $(par_touch_access_default "${batch[@]}")))
            [[ -n "$setfile" ]] && fail=$((fail + $(_par_run "$MAX_PARALLEL" "$cmd_btime" "${batch[@]}")))
        else
            $modify_btime && [[ -n "$setfile" ]] && fail=$((fail + $(_par_run "$MAX_PARALLEL" "$cmd_btime" "${batch[@]}")))
            $modify_mtime && fail=$((fail + $(_par_run "$MAX_PARALLEL" "$cmd_mtime" "${batch[@]}")))
            $modify_atime && fail=$((fail + $(_par_run "$MAX_PARALLEL" "$cmd_atime" "${batch[@]}")))
        fi
        processed=$((processed + ${#batch[@]}))
        show_progress "$processed" "$file_count"
    done
    finish_progress

    echo "文件处理完成!" >&2
    echo "$fail"
}

# 目录修改编排：扫描目标目录 → 解析目标时间 → 预览 → 确认 → 执行 → 结果。
# 文件夹项交给 reset_dir_times（始终回 DEFAULT），文件项交给 apply_file_times（用户时间）。
process_directory() {
    local target_path="$1"
    local cli_date="${2:-}"
    local cli_time="${3:-}"

    echo "正在扫描目录..."

    local dir_count=0 file_count=0
    local dirs=()
    local files=()
    while IFS= read -r -d '' item; do
        if [[ -d "$item" ]]; then
            dirs+=("$item")
            dir_count=$((dir_count + 1))
        elif [[ -f "$item" ]]; then
            files+=("$item")
            file_count=$((file_count + 1))
        fi
    done < <(find_items "$target_path")

    if [[ $dir_count -eq 0 && $file_count -eq 0 ]]; then
        return 0
    fi

    echo "目标信息: 共${dir_count}个文件夹, ${file_count}个文件"

    if (( dir_count + file_count > MAX_FILES_WARN )); then
        echo "${COL_YELLOW}警告:${COL_RESET} 文件/文件夹数量超过 ${MAX_FILES_WARN}, 操作可能较慢"
        confirm_modify || { abort; return 1; }
    fi

    local target_sf target_tc target_display parsed
    parsed=$(resolve_target_or_abort "$cli_date" "$cli_time") || return 1
    IFS='|' read -r target_sf target_tc target_display <<< "$parsed"

    local old_dir_created="" old_dir_modified="" old_dir_accessed=""
    local old_file_created="" old_file_modified="" old_file_accessed=""
    [[ $dir_count -gt 0 ]] && IFS='|' read -r old_dir_created old_dir_modified old_dir_accessed < <(get_times "${dirs[0]}")
    [[ $file_count -gt 0 ]] && IFS='|' read -r old_file_created old_file_modified old_file_accessed < <(get_times "${files[0]}")

    preview_changes "$dir_count" "$file_count" "${dirs[0]-}" "${files[0]-}" \
        "$old_dir_created" "$old_dir_modified" "$old_dir_accessed" \
        "$old_file_created" "$old_file_modified" "$old_file_accessed" \
        "$target_display"

    confirm_modify || { abort; return 1; }

    local fail_count=0
    [[ $dir_count -gt 0 ]] && fail_count=$((fail_count + $(reset_dir_times "$dir_count" "${dirs[@]}")))
    [[ $file_count -gt 0 ]] && fail_count=$((fail_count + $(apply_file_times "$file_count" "$target_tc" "$target_sf" "${files[@]}")))

    show_modify_result "$fail_count" "$dir_count" "$file_count" "${dirs[0]-}" "${files[0]-}" \
        "$old_dir_created" "$old_dir_modified" "$old_dir_accessed" \
        "$old_file_created" "$old_file_modified" "$old_file_accessed"
    echo ""
}

preview_changes() {
    local dir_count=$1 file_count=$2 dir_path=$3 file_path=$4
    local old_dc=$5 old_dm=$6 old_da=$7
    local old_fc=$8 old_fm=$9 old_fa=${10}
    local target_disp=${11}

    echo ""
    echo "预览修改:"
    if [[ $dir_count -gt 0 ]]; then
        if [[ "$default_times" == "true" ]]; then
            echo "  文件夹(${dir_count}个): 所有时间 → ${DEFAULT_DISPLAY}"
            echo "    [文件夹] $(basename "$dir_path")"
            echo "      创建: $old_dc → $DEFAULT_DISPLAY"
            echo "      修改: $old_dm → $DEFAULT_DISPLAY"
            echo "      访问: $old_da → $DEFAULT_DISPLAY"
        else
            echo "  文件夹(${dir_count}个): 所有时间 → ${DEFAULT_DISPLAY}"
            echo "    [文件夹] $(basename "$dir_path")"
            echo "      创建: $old_dc → $DEFAULT_DISPLAY"
            echo "      修改: $old_dm → $DEFAULT_DISPLAY"
            echo "      访问: $old_da → $DEFAULT_DISPLAY"
        fi
        echo ""
    fi
    if [[ $file_count -gt 0 ]]; then
        if [[ "$default_times" == "true" ]]; then
            echo "  文件(${file_count}个): 创建+修改 → ${target_disp}; 访问时间 → ${DEFAULT_DISPLAY}"
            echo "    [文件] $(basename "$file_path")"
            echo "      创建: $old_fc → $target_disp"
            echo "      修改: $old_fm → $target_disp"
            echo "      访问: $old_fa → $DEFAULT_DISPLAY"
        else
            echo "  文件(${file_count}个):"
            echo "    [文件] $(basename "$file_path")"
            $modify_btime && echo "      创建: $old_fc → $target_disp"
            $modify_mtime && echo "      修改: $old_fm → $target_disp"
            $modify_atime && echo "      访问: $old_fa → $target_disp"
        fi
        echo ""
    fi
}

show_modify_result() {
    local fail_count=$1 dir_count=$2 file_count=$3 dir_path=$4 file_path=$5
    local old_dc=$6 old_dm=$7 old_da=$8
    local old_fc=$9 old_fm=${10} old_fa=${11}

    if [[ $fail_count -gt 0 ]]; then
        echo "${COL_YELLOW}警告:${COL_RESET} 有 $fail_count 个操作失败"
    fi
    echo ""
    if [[ $dir_count -gt 0 ]]; then
        local new_created new_modified new_accessed
        IFS='|' read -r new_created new_modified new_accessed < <(get_times "$dir_path")
        echo "文件夹示例(${dir_count}个): $(basename "$dir_path")"
        echo "  创建: $old_dc → $new_created"
        echo "  修改: $old_dm → $new_modified"
        echo "  访问: $old_da → $new_accessed"
    fi
    if [[ $file_count -gt 0 ]]; then
        [[ $dir_count -gt 0 ]] && echo ""
        local new_created new_modified new_accessed
        IFS='|' read -r new_created new_modified new_accessed < <(get_times "$file_path")
        echo "文件示例(${file_count}个): $(basename "$file_path")"
        echo "  创建: $old_fc → $new_created"
        echo "  修改: $old_fm → $new_modified"
        echo "  访问: $old_fa → $new_accessed"
    fi
}

# ============ 处理入口 ============

modify_mode() {
    if ! $modify_btime && ! $modify_mtime && ! $modify_atime; then
        modify_btime=true
        modify_mtime=true
        modify_atime=true
        default_times=true
    fi

    if $modify_btime; then
        check_setfile || return 1
    fi

    local raw_path="${1:-}"
    [[ -z "$raw_path" ]] && { echo ""; read -erp "目标路径: " raw_path || return 1; }
    local target_path
    target_path=$(clean_path "$raw_path")

    local cli_date="${2:-}"
    local cli_time="${3:-}"

    if [[ ! -e "$target_path" ]]; then
        echo "${COL_RED}错误:${COL_RESET} 路径不存在"
        return 1
    fi

    echo ""
    process_directory "$target_path" "$cli_date" "$cli_time" || true
}

# ============ 帮助 ============

show_usage() {
    echo "Antiquer v$VERSION — macOS 文件/文件夹时间戳查看与修改工具"
    echo ""
    echo "用法:"
    echo "  $(basename "$0")                                    TUI 模式"
    echo "  $(basename "$0") <路径>                              查看时间戳"
    echo "  $(basename "$0") <路径> <日期> [时间]                 修改时间戳"
    echo "  $(basename "$0") <选项> <路径> <日期> [时间]          带选项修改"
    echo ""
    echo "选项 (顺序: -H < -A or -b/-m/-a < 路径 < 日期 < 时间):"
    echo "  -h, --help                    显示此帮助（必须是唯一参数）"
    echo "  -V, --version                 显示版本（必须是唯一参数）"
    echo "  -H, --hidden                  包含隐藏文件 (. 开头)"
    echo "  -A, --all                     所有时间全改为用户指定值"
    echo "  -b, --birth, -c, --create     仅修改创建时间"
    echo "  -m, --modify                  仅修改修改时间"
    echo "  -a, --access                  仅修改访问时间"
    echo ""
    echo "选项规则:"
    echo "  -H 必须是第一个选项（在 -A/-b/-m/-a 之前）"
    echo "  -A 不能与 -b/-c/-m/-a 同时使用"
    echo "  选项必须在路径之前"
    echo "  短选项可合并: -bm = -b -m, -bma = -b -m -a"
    echo "  -b 和 -c 是别名，不能合并在一起"
    echo "  无选项时: 创建+修改时间设为目标值，访问时间重置为 1980-01-01"
    echo ""
    echo "参数:"
    echo "  路径    目标文件或文件夹"
    echo "  日期    YYYY-MM-DD 格式"
    echo "  时间    HH:MM:SS 格式 (默认 00:00:00)"
    echo ""
    echo "CLI 模式说明 (带参数运行时):"
    echo "  - 自动跳过所有确认提示，直接执行操作"
    echo "  - 修改模式: 创建+修改时间设为指定值, 访问时间固定重置为 1980-01-01"
    echo "  - 修改模式: 文件夹始终重置为 1980-01-01(容器类文件，用户指定值无效)"
    echo "  - 修改模式: 需 Xcode 命令行工具(SetFile)"
    echo ""
    echo "示例:"
    echo "  $(basename "$0") /path/to/file"
    echo "  $(basename "$0") /path/to/file 2017-03-03"
    echo "  $(basename "$0") -b -m -a /path/to/file 2017-03-03 12:00:00"
    echo "  $(basename "$0") -bma /path/to/file 2017-03-03"
    echo "  $(basename "$0") -H -A /path/to/file 2017-03-03 12:00:00"
    echo "  $(basename "$0") -H /path/to/file"
    echo "  $(basename "$0") --hidden --all /path/to/file 2017-03-03"
    echo "  $(basename "$0") --hidden --create -ma /path/to/file 2017-03-03"
    echo ""
}

# ============ CLI 模式 ============

if [[ $# -ge 1 ]]; then
    case "$1" in
        -h|--help)
            if [[ $# -gt 1 ]]; then
                echo "${COL_RED}错误:${COL_RESET} -h/--help 不能与其他参数同时使用" >&2
                exit 1
            fi
            show_usage
            exit 0
            ;;
        -V|--version)
            if [[ $# -gt 1 ]]; then
                echo "${COL_RED}错误:${COL_RESET} -V/--version 不能与其他参数同时使用" >&2
                exit 1
            fi
            echo "Antiquer 版本 $VERSION"
            exit 0
            ;;
        *)
            parsed_args=()
            has_options=false
            no_more_opts=false
            found_H=false
            found_A=false
            found_bma=false
            found_positional=false

            for arg in "$@"; do
                if $no_more_opts; then
                    parsed_args+=("$arg")
                    continue
                fi
                case "$arg" in
                    -H|--hidden)
                        if $found_positional; then
                            echo "${COL_RED}错误:${COL_RESET} -H/--hidden 必须放在路径之前" >&2
                            exit 1
                        fi
                        if $found_A || $found_bma; then
                            echo "${COL_RED}错误:${COL_RESET} -H/--hidden 必须是第一个选项" >&2
                            exit 1
                        fi
                        if $found_H; then
                            echo "${COL_YELLOW}警告:${COL_RESET} 重复选项 -H/--hidden" >&2
                        fi
                        # -H 不设 has_options：它作为修饰符，查看和修改模式都能用
                        show_hidden=true; found_H=true
                        ;;
                    -A|--all)
                        if $found_positional; then
                            echo "${COL_RED}错误:${COL_RESET} -A/--all 必须放在路径之前" >&2
                            exit 1
                        fi
                        if $found_bma; then
                            echo "${COL_RED}错误:${COL_RESET} -A/--all 不能与 -b/-c/-m/-a 同时使用" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_YELLOW}警告:${COL_RESET} 重复选项 -A/--all" >&2
                        fi
                        modify_btime=true; modify_mtime=true; modify_atime=true
                        has_options=true; found_A=true
                        ;;
                    -b|--birth|-c|--create)
                        if $found_positional; then
                            echo "${COL_RED}错误:${COL_RESET} 选项必须放在路径之前" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}错误:${COL_RESET} -b/-c/--birth/--create 不能与 -A/--all 同时使用" >&2
                            exit 1
                        fi
                        if $modify_btime; then
                            echo "${COL_YELLOW}警告:${COL_RESET} 重复选项 $arg" >&2
                        fi
                        modify_btime=true; has_options=true; found_bma=true
                        ;;
                    -m|--modify)
                        if $found_positional; then
                            echo "${COL_RED}错误:${COL_RESET} 选项必须放在路径之前" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}错误:${COL_RESET} -m/--modify 不能与 -A/--all 同时使用" >&2
                            exit 1
                        fi
                        if $modify_mtime; then
                            echo "${COL_YELLOW}警告:${COL_RESET} 重复选项 $arg" >&2
                        fi
                        modify_mtime=true; has_options=true; found_bma=true
                        ;;
                    -a|--access)
                        if $found_positional; then
                            echo "${COL_RED}错误:${COL_RESET} 选项必须放在路径之前" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}错误:${COL_RESET} -a/--access 不能与 -A/--all 同时使用" >&2
                            exit 1
                        fi
                        if $modify_atime; then
                            echo "${COL_YELLOW}警告:${COL_RESET} 重复选项 $arg" >&2
                        fi
                        modify_atime=true; has_options=true; found_bma=true
                        ;;
                    -V|--version)
                        echo "${COL_RED}错误:${COL_RESET} -V/--version 不能与其他参数同时使用" >&2
                        exit 1
                        ;;
                    -h|--help)
                        echo "${COL_RED}错误:${COL_RESET} -h/--help 不能与其他参数同时使用" >&2
                        exit 1
                        ;;
                    --)
                        no_more_opts=true
                        ;;
                    -b[bcma]*|-c[bcma]*|-m[bcma]*|-a[bcma]*)
                        if $found_positional; then
                            echo "${COL_RED}错误:${COL_RESET} 选项必须放在路径之前" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}错误:${COL_RESET} 合并选项不能与 -A/--all 同时使用" >&2
                            exit 1
                        fi
                        flags="${arg#-}"
                        has_b=false; has_c=false; i=; ch=
                        for ((i=0; i<${#flags}; i++)); do
                            ch="${flags:$i:1}"
                            case "$ch" in
                                b) has_b=true ;;
                                c) has_c=true ;;
                                m) ;;
                                a) ;;
                                *) echo "${COL_RED}错误:${COL_RESET} $arg 中存在未知选项 -$ch" >&2; exit 1 ;;
                            esac
                        done
                        if $has_b && $has_c; then
                            echo "${COL_YELLOW}警告:${COL_RESET} -b 和 -c 是别名，不能在 $arg 中同时使用" >&2
                        fi
                        for ((i=0; i<${#flags}; i++)); do
                            ch="${flags:$i:1}"
                            case "$ch" in
                                b|c)
                                    if $modify_btime; then echo "${COL_YELLOW}警告:${COL_RESET} $arg 中存在重复选项 -$ch" >&2; fi
                                    modify_btime=true
                                    ;;
                                m)
                                    if $modify_mtime; then echo "${COL_YELLOW}警告:${COL_RESET} $arg 中存在重复选项 -m" >&2; fi
                                    modify_mtime=true
                                    ;;
                                a)
                                    if $modify_atime; then echo "${COL_YELLOW}警告:${COL_RESET} $arg 中存在重复选项 -a" >&2; fi
                                    modify_atime=true
                                    ;;
                            esac
                        done
                        has_options=true; found_bma=true
                        ;;
                    -*)
                        echo "${COL_RED}错误:${COL_RESET} 未知选项: $arg" >&2
                        exit 1
                        ;;
                    *)
                        found_positional=true
                        parsed_args+=("$arg")
                        ;;
                esac
            done

            find_setfile
            path="${parsed_args[0]:-}"
            date="${parsed_args[1]-}"
            time="${parsed_args[2]-00:00:00}"

            if [[ ${#parsed_args[@]} -gt 3 ]]; then
                echo "${COL_RED}错误:${COL_RESET} 未知参数: ${parsed_args[3]}" >&2
                exit 1
            fi

            if [[ -z "$path" ]]; then
                echo "${COL_RED}错误:${COL_RESET} 缺少路径参数" >&2
                exit 1
            fi

            cli_mode=true

            if [[ "$has_options" == "false" ]]; then
                if [[ ${#parsed_args[@]} -eq 1 ]]; then
                    view_mode "$path"
                    exit $?
                fi
                check_setfile || exit 1
                default_times=true
                modify_mode "$path" "$date" "$time"
                exit $?
            fi

            if $modify_btime; then
                check_setfile || exit 1
            fi
            if [[ ${#parsed_args[@]} -lt 2 ]]; then
                echo "${COL_RED}错误:${COL_RESET} 使用选项时需提供日期参数" >&2
                exit 1
            fi
            modify_mode "$path" "$date" "$time"
            exit $?
            ;;
    esac
fi

# ============ 主菜单 ============

main_menu() {
    echo "工作模式:"
    echo ""
    echo " [1] 查看模式"
    [[ -n "$setfile" ]] && echo " [2] 修改模式"
    echo " [0] 退出"
    echo ""
    local mode
    if [[ -n "$setfile" ]]; then
        read -erp "选择模式(1/2): " mode || return 1
    else
        read -erp "选择模式(1/0): " mode || return 1
    fi

    case "$mode" in
        1) view_mode || true ;;
        2) [[ -n "$setfile" ]] && modify_mode || true ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

# ============ TUI 模式 ============

find_setfile
if [[ -z "$setfile" ]]; then
    echo "提示: 未找到 SetFile, 修改模式需要 Xcode 命令行工具"
    read -erp "是否安装(Y/n): " _install_choice || true
    if [[ "$_install_choice" =~ ^[Yy]$ ]]; then
        echo "正在安装 Xcode 命令行工具…"
        xcode-select --install
    fi
    echo ""
    echo "[仅查看模式]"
fi
echo ""

while true; do
    main_menu || break
done
