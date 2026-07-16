#!/bin/bash

# Antiquer — macOS file/folder timestamp viewer and modifier
# TUI (interactive menu):
# - View: tree stats + optional fix (folders: all → 1980; files: access only → 1980)
# - Modify: folders: all → 1980; files: birth+mod → user input, access → 1980
# CLI (command-line args):
# - View: <path> ; Modify: <path> <date> [time] (birth+mod → user input, access → 1980)
# - Flags: -b/--birth/-c/--create (birth) -m/--modify (mod) -a/--access (access) -A/--all (all timestamps)
# - Other: -h/--help (help) -H/--hidden (include hidden files)
# Deps: macOS built-in tools / Xcode SetFile (modify birth time)

# Platform check: only Darwin (macOS) is supported
[[ "$(uname -s)" == "Darwin" ]] || { echo "${COL_RED}Error:${COL_RESET} this script only supports macOS"; exit 1; }

# Strict mode: exit on error (-e), undefined var error (-u), pipefail (-o pipefail)
set -euo pipefail

# ============ Global variables ============

# Temp directory for scan stats
temp_dir=""
# SetFile path (null = birth time modification unavailable)
setfile=""
# CLI mode (skip confirmations, act immediately)
cli_mode=false
# Modify birth time (requires SetFile)
modify_btime=false
# Modify modification time (touch -m)
modify_mtime=false
# Modify access time (touch -a)
modify_atime=false
# No flags specified: birth+mod → user input, access → 1980; folders: all → 1980
default_times=false
# Include dotfiles
show_hidden=false

# ============ Constants ============

# Interactive fallback defaults
readonly DEFAULT_DATE="1980-01-01"
readonly DEFAULT_TIME="00:00:00"
# SetFile format (12h + AM/PM, local TZ, no TZ support)
readonly DEFAULT_SF="01/01/1980 12:00:00 AM"
# touch format (YYYYMMDDhhmm.SS, 24h, local TZ, no TZ support)
readonly DEFAULT_TC="198001010000.00"
# Display format
readonly DEFAULT_DISPLAY="1980-01-01 00:00:00"
# Max parallel processes
readonly MAX_PARALLEL=2
# Max tree depth
readonly MAX_TREE_DEPTH=500
# Batch size
readonly BATCH_SIZE=100
# Warn threshold for large operations
readonly MAX_FILES_WARN=10000
# Version
readonly VERSION="0.1"

# Color output constants
COL_RED=$([[ -t 2 ]] && tput setaf 1 2>/dev/null || true); readonly COL_RED
COL_YELLOW=$([[ -t 2 ]] && tput setaf 3 2>/dev/null || true); readonly COL_YELLOW
COL_RESET=$([[ -t 2 ]] && tput sgr0 2>/dev/null || true); readonly COL_RESET

# ============ Interrupt & cleanup ============

clean_temp() {
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir"
        temp_dir=""
    fi
}

trap clean_temp EXIT
trap 'echo ""; echo "Operation interrupted"; clean_temp; exit 130' INT

# ============ SetFile dependency ============

find_setfile() {
    if command -v SetFile &>/dev/null; then
        setfile="SetFile"
    elif [[ -x "/Developer/Tools/SetFile" ]]; then
        setfile="/Developer/Tools/SetFile"
    fi
}

check_setfile() {
    if [[ -z "$setfile" ]]; then
        echo "${COL_RED}Error:${COL_RESET} Xcode Command Line Tools required, run xcode-select --install" >&2
        return 1
    fi
}

# ============ Common utilities ============

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

# ============ User confirmation ============

confirm_modify() {
    $cli_mode && return 0
    local reply
    read -erp "Proceed with modification (y/N): " reply || return 1
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

abort() {
    local do_clean="${1:-false}"
    if $do_clean; then
        echo "Canceled..."
        clean_temp
    else
        echo "Operation canceled"
        echo ""
    fi
    return 0
}

# ============ Progress bar ============

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

# ============ Parallel execution ============

# Parallel exec: each failure outputs ".", returns total failure count
# Note: 2>/dev/null hides xargs errors (e.g. missing commands); remove for debugging
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

# ============ Batch folder processing ============

# Folders always reset to DEFAULT(1980-01-01), ignoring user-specified dates.
# Reason: folders are containers; their timestamps affect Finder sorting.
# Resetting all to the same value prevents mix-ups.
batch_reset_dirs_default() {
    local total=$1; shift
    [[ $total -eq 0 ]] && { echo 0; return 0; }
    local items=("$@")
    local i batch fail=0
    echo "" >&2
    echo "Processing folders…" >&2
    for ((i=0; i<total; i+=BATCH_SIZE)); do
        batch=("${items[@]:i:BATCH_SIZE}")
        fail=$((fail + $(par_touch_both_default "${batch[@]}")))
        if [[ -n "$setfile" ]]; then
            fail=$((fail + $(par_setfile_create_default "${batch[@]}")))
        fi
        show_progress "$((i + ${#batch[@]}))" "$total"
    done
    finish_progress
    echo "Folders processed!" >&2
    echo "$fail"
}

# ============ Date utilities ============

resolve_target_datetime() {
    local input_date="${1:-}"
    local input_time="${2:-}"
    local interactive=false

    [[ -z "$input_date" && -z "$input_time" ]] && interactive=true

    while true; do
        if $interactive; then
            echo >&2 ""
            [[ -z "$input_date" ]] && { read -erp "Target date (default ${DEFAULT_DATE}): " input_date || return 1; }
            [[ -z "$input_time" ]] && { read -erp "Target time (default ${DEFAULT_TIME}): " input_time || return 1; }
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
            echo >&2 "Error: invalid format, use YYYY-MM-DD for date and HH:MM:SS for time"
            $interactive && { input_date=""; input_time=""; continue; } || return 1
        fi

        local y_check="${combined:0:4}"
        if [[ $((10#$y_check)) -lt 1970 || $((10#$y_check)) -gt 2038 ]]; then
            echo >&2 "Error: SetFile only supports dates from 1970-01-01 to 2038-01-18"
            $interactive && { input_date=""; input_time=""; continue; } || return 1
        fi

        if ! date -jf "%Y-%m-%d %H:%M:%S" "$combined" >/dev/null 2>&1; then
            echo >&2 "Error: invalid date/time (e.g. Feb 30)"
            $interactive && { input_date=""; input_time=""; continue; } || return 1
        fi

        local year="${combined:0:4}"
        local month="${combined:5:2}"
        local day="${combined:8:2}"

        # SetFile 32-bit time_t limit: max 2038-01-18
        if [[ $((10#$year)) -eq 2038 && ( $((10#$month)) -gt 1 || ( $((10#$month)) -eq 1 && $((10#$day)) -gt 18 ) ) ]]; then
            echo >&2 "Error: SetFile only supports dates up to 2038-01-18"
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

# ============ View mode ============

show_default_stats() {
    local dir_default_count=$1 file_default_count=$2

    if [[ $dir_default_count -eq 0 && $file_default_count -eq 0 ]]; then
        echo "No items at default"
        return 0
    fi

    local stats_file="$temp_dir/stats"
    local temp_count="$temp_dir/tcount"
    local example_file="$temp_dir/example"

    [[ -f "$stats_file" ]] && sort "$stats_file" | uniq -c | sort -rn > "$temp_count"
    [[ ! -f "$temp_count" ]] && touch "$temp_count"
    local combo_count
    combo_count=$(wc -l < "$temp_count" | tr -d ' ')
    echo "Stats:"
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
                    [[ "$item_type" == "dir" ]] && item_type="Folder" || item_type="File"
                    example_file_name="$ename"
                fi
                local label="$item_type"
                [[ "$label" == "Folder" ]] && label="folder" || label="file"
                [[ $count -gt 1 ]] && label="${label}s"
                echo "  [$item_type] $example_file_name ($count $label)"
                echo "    Birth: $ctime"
                echo "    Mod:   $mtime"
                echo "    Acc:   $atime"
                echo ""
            fi
        fi
    done < "$temp_count"
    if [[ $combo_count -gt $max_display ]]; then
        echo "  ...(${combo_count} timestamp groups total)"
        echo ""
    fi
    echo "  (${dir_default_count} folders, ${file_default_count} files already at default)"
}

show_modify_list() {
    local non_default_file="$temp_dir/non_default"

    if [[ -s "$non_default_file" ]]; then
        local modify_dir_count=0 modify_file_count=0 type name
        echo ""
        echo "To modify ($(wc -l < "$non_default_file" | tr -d ' ') items):"
        while IFS='|' read -r type ctime mtime atime name; do
            if [[ "$type" == "dir" ]]; then
                modify_dir_count=$((modify_dir_count + 1))
                echo "  [Folder] $name"
                echo "    Birth: $ctime → $DEFAULT_DISPLAY"
                echo "    Mod:   $mtime → $DEFAULT_DISPLAY"
                echo "    Acc:   $atime → $DEFAULT_DISPLAY"
            else
                modify_file_count=$((modify_file_count + 1))
                echo "  [File] $name"
                echo "    Birth: $ctime"
                echo "    Mod:   $mtime"
                echo "    Acc:   $atime → $DEFAULT_DISPLAY"
            fi
            echo ""
        done < "$non_default_file"
        echo "  (${modify_dir_count} folder$( ((modify_dir_count != 1)) && echo s), ${modify_file_count} file$( ((modify_file_count != 1)) && echo s))"
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
        echo "Modifying files…"
        local processed=0 batch i
        for ((i=0; i<nd_file_count; i+=BATCH_SIZE)); do
            batch=("${nd_files[@]:i:BATCH_SIZE}")
            fail_count=$((fail_count + $(par_touch_access_default "${batch[@]}")))
            processed=$((processed + ${#batch[@]}))
            show_progress "$processed" "$nd_file_count"
        done
        finish_progress
        echo "Files processed!"
    fi
    if [[ $fail_count -gt 0 ]]; then
        echo "${COL_YELLOW}Warning:${COL_RESET} $fail_count operations failed"
    fi
    echo ""
    if [[ $nd_dir_count -gt 0 ]]; then
        IFS='|' read -r ctime mtime atime < <(get_times "${nd_dirs[0]}")
        echo "Folder sample (${nd_dir_count} folder$( ((nd_dir_count != 1)) && echo s)): $(basename "${nd_dirs[0]}")"
        echo "  Birth: $ctime"
        echo "  Mod:   $mtime"
        echo "  Acc:   $atime"
    fi
    if [[ $nd_file_count -gt 0 ]]; then
        [[ $nd_dir_count -gt 0 ]] && echo ""
        IFS='|' read -r ctime mtime atime < <(get_times "${nd_files[0]}")
        echo "File sample (${nd_file_count} file$( ((nd_file_count != 1)) && echo s)): $(basename "${nd_files[0]}")"
        echo "  Birth: $ctime"
        echo "  Mod:   $mtime"
        echo "  Acc:   $atime"
    fi
}

# ============ Tree display ============

print_tree() {
    local path="$1"
    local prefix="$2"
    local is_last="$3"
    local is_root="$4"
    local depth="${5:-0}"
    local ctime mtime atime item

    if (( depth > MAX_TREE_DEPTH )); then
        echo "${prefix}...(max depth reached, truncated)"
        return 0
    fi

    local base
    base=$(basename "$path")

    local type="File" suffix=""
    [[ -d "$path" ]] && { type="Folder"; suffix="/"; }

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
    echo "${time_prefix}Birth: $ctime"
    echo "${time_prefix}Mod:   $mtime"
    echo "${time_prefix}Acc:   $atime"

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
            echo "${children_prefix}...(${extra} more items)"
            echo "${children_prefix}"
        fi
        return 0
    else
                echo "${time_prefix}"
    fi
}

# ============ View mode entry ============

view_mode() {
    local raw_path="${1:-}"
    [[ -z "$raw_path" ]] && { echo ""; read -erp "Target path: " raw_path || return 1; }
    local target_path
    target_path=$(clean_path "$raw_path")

    if [[ ! -e "$target_path" ]]; then
        echo "${COL_RED}Error:${COL_RESET} path does not exist"
        return 1
    fi

    echo ""
    echo "Scanning directory..."

    if [[ -f "$target_path" ]]; then
        local file_count=1 dir_count=0
        echo "Done, ${dir_count} folders, ${file_count} files found"
        echo ""
        echo "[File] $(basename "$target_path")"

        IFS='|' read -r ctime mtime atime < <(get_times "$target_path")
        echo "  Birth: $ctime"
        echo "  Mod:   $mtime"
        echo "  Acc:   $atime"
        echo ""
        return 0
    fi

    temp_dir=$(mktemp -d) || { echo "${COL_RED}Error:${COL_RESET} cannot create temp directory"; return 1; }
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
            # Folder: reset all timestamps
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
            # File: only reset access time, birth+mod kept
            if [[ "$atime" != "$DEFAULT_DISPLAY" ]]; then
                echo "file|$ctime|$mtime|$atime|$(basename "$item")" >> "$non_default_file"
                printf '%s\0' "$item" >> "$non_default_paths"
            else
                stats_file_count=$((stats_file_count + 1))
                echo "$key" >> "$stats_file"
            fi
        fi
    done < <(find_items "$target_path")

    echo "Done, ${dir_count} folders, ${file_count} files found"
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

# ============ Modify mode ============

# Folders always reset to DEFAULT(1980-01-01), ignoring user-specified dates.
# Reason: folders sort by creation time in Finder; resetting to a fixed value prevents mixed ordering.
reset_dir_times() {
    local dir_count=$1; shift
    batch_reset_dirs_default "$dir_count" "$@"
}

# Modify file timestamps using user-specified target_tc/target_sf.
# default_times=true:  set mtime+atime+btime, atime forced to DEFAULT
# default_times=false: modify selectively based on modify_{mtime,atime,btime} flags
apply_file_times() {
    local file_count=$1 target_tc=$2 target_sf=$3; shift 3
    local files=("$@")
    local fail=0

    echo "" >&2
    echo "Modifying files…" >&2

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

    echo "Files processed!" >&2
    echo "$fail"
}

# Directory modification orchestration:
# Scan target → resolve time → preview → confirm → execute → result.
# Folders go to reset_dir_times (always DEFAULT), files to apply_file_times (user time).
process_directory() {
    local target_path="$1"
    local cli_date="${2:-}"
    local cli_time="${3:-}"

    echo "Scanning directory..."

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

    echo "Target: ${dir_count} folders, ${file_count} files"

    if (( dir_count + file_count > MAX_FILES_WARN )); then
        echo "${COL_YELLOW}Warning:${COL_RESET} more than ${MAX_FILES_WARN} items, operation may be slow"
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
    echo "Preview changes:"
    if [[ $dir_count -gt 0 ]]; then
        if [[ "$default_times" == "true" ]]; then
            echo "  Folders (${dir_count}): all → ${DEFAULT_DISPLAY}"
            echo "    [Folder] $(basename "$dir_path")"
            echo "      Birth: $old_dc → $DEFAULT_DISPLAY"
            echo "      Mod:   $old_dm → $DEFAULT_DISPLAY"
            echo "      Acc:   $old_da → $DEFAULT_DISPLAY"
        else
            echo "  Folders (${dir_count}): all → ${DEFAULT_DISPLAY}"
            echo "    [Folder] $(basename "$dir_path")"
            echo "      Birth: $old_dc → $DEFAULT_DISPLAY"
            echo "      Mod:   $old_dm → $DEFAULT_DISPLAY"
            echo "      Acc:   $old_da → $DEFAULT_DISPLAY"
        fi
        echo ""
    fi
    if [[ $file_count -gt 0 ]]; then
        if [[ "$default_times" == "true" ]]; then
            echo "  Files (${file_count}): birth+mod → ${target_disp}; access → ${DEFAULT_DISPLAY}"
            echo "    [File] $(basename "$file_path")"
            echo "      Birth: $old_fc → $target_disp"
            echo "      Mod:   $old_fm → $target_disp"
            echo "      Acc:   $old_fa → $DEFAULT_DISPLAY"
        else
            echo "  Files (${file_count}):"
            echo "    [File] $(basename "$file_path")"
            $modify_btime && echo "      Birth: $old_fc → $target_disp"
            $modify_mtime && echo "      Mod:   $old_fm → $target_disp"
            $modify_atime && echo "      Acc:   $old_fa → $target_disp"
        fi
        echo ""
    fi
}

show_modify_result() {
    local fail_count=$1 dir_count=$2 file_count=$3 dir_path=$4 file_path=$5
    local old_dc=$6 old_dm=$7 old_da=$8
    local old_fc=$9 old_fm=${10} old_fa=${11}

    if [[ $fail_count -gt 0 ]]; then
        echo "${COL_YELLOW}Warning:${COL_RESET} $fail_count operations failed"
    fi
    echo ""
    if [[ $dir_count -gt 0 ]]; then
        local new_created new_modified new_accessed
        IFS='|' read -r new_created new_modified new_accessed < <(get_times "$dir_path")
        echo "Folder sample (${dir_count} folder$( ((dir_count != 1)) && echo s)): $(basename "$dir_path")"
        echo "  Birth: $old_dc → $new_created"
        echo "  Mod:   $old_dm → $new_modified"
        echo "  Acc:   $old_da → $new_accessed"
    fi
    if [[ $file_count -gt 0 ]]; then
        [[ $dir_count -gt 0 ]] && echo ""
        local new_created new_modified new_accessed
        IFS='|' read -r new_created new_modified new_accessed < <(get_times "$file_path")
        echo "File sample (${file_count} file$( ((file_count != 1)) && echo s)): $(basename "$file_path")"
        echo "  Birth: $old_fc → $new_created"
        echo "  Mod:   $old_fm → $new_modified"
        echo "  Acc:   $old_fa → $new_accessed"
    fi
}

# ============ Entry point ============

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
    [[ -z "$raw_path" ]] && { echo ""; read -erp "Target path: " raw_path || return 1; }
    local target_path
    target_path=$(clean_path "$raw_path")

    local cli_date="${2:-}"
    local cli_time="${3:-}"

    if [[ ! -e "$target_path" ]]; then
        echo "${COL_RED}Error:${COL_RESET} path does not exist"
        return 1
    fi

    echo ""
    process_directory "$target_path" "$cli_date" "$cli_time" || true
}

# ============ Help ============

show_usage() {
    echo "Antiquer v$VERSION — macOS file/folder timestamp viewer and modifier"
    echo ""
    echo "Usage:"
    echo "  $(basename "$0")                                    TUI mode"
    echo "  $(basename "$0") <path>                             View timestamps"
    echo "  $(basename "$0") <path> <date> [time]               Modify timestamps"
    echo "  $(basename "$0") <flags> <path> <date> [time]       Modify with flags"
    echo ""
    echo "Flags (order: -H < -A or -b/-m/-a < path < date < time):"
    echo "  -h, --help                    Show this help (must be sole argument)"
    echo "  -V, --version                 Show version (must be sole argument)"
    echo "  -H, --hidden                  Include hidden files (dotfiles)"
    echo "  -A, --all                     All timestamps set to user value"
    echo "  -b, --birth, -c, --create     Birth time only"
    echo "  -m, --modify                  Modification time only"
    echo "  -a, --access                  Access time only"
    echo ""
    echo "Flag rules:"
    echo "  -H must be the first flag (before -A/-b/-m/-a)"
    echo "  -A cannot be combined with -b/-c/-m/-a"
    echo "  Flags must appear before path"
    echo "  Short options can be merged: -bm = -b -m, -bma = -b -m -a"
    echo "  -b and -c are aliases, cannot be merged together"
    echo "  No flag: birth+mod set to value, access reset to 1980-01-01"
    echo ""
    echo "Arguments:"
    echo "  path      Target file or folder"
    echo "  date      YYYY-MM-DD format"
    echo "  time      HH:MM:SS format (default 00:00:00)"
    echo ""
    echo "CLI notes (when args provided):"
    echo "  - Skips all confirmation prompts, executes immediately"
    echo "  - Modify mode: birth+mod set to specified value, access always reset to 1980-01-01"
    echo "  - Folders always reset to 1980-01-01 (user value ignored for folders)"
    echo "  - Xcode CLI tools (SetFile) required for birth time modification"
    echo ""
    echo "Examples:"
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

# ============ CLI mode ============

if [[ $# -ge 1 ]]; then
    case "$1" in
        -h|--help)
            if [[ $# -gt 1 ]]; then
                echo "${COL_RED}Error:${COL_RESET} -h/--help cannot be combined with other arguments" >&2
                exit 1
            fi
            show_usage
            exit 0
            ;;
        -V|--version)
            if [[ $# -gt 1 ]]; then
                echo "${COL_RED}Error:${COL_RESET} -V/--version cannot be combined with other arguments" >&2
                exit 1
            fi
            echo "Antiquer version $VERSION"
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
                            echo "${COL_RED}Error:${COL_RESET} -H/--hidden must appear before path" >&2
                            exit 1
                        fi
                        if $found_A || $found_bma; then
                            echo "${COL_RED}Error:${COL_RESET} -H/--hidden must be the first flag" >&2
                            exit 1
                        fi
                        if $found_H; then
                            echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option -H/--hidden" >&2
                        fi
                        # -H does NOT set has_options: it acts as a modifier for both view and modify modes
                        show_hidden=true; found_H=true
                        ;;
                    -A|--all)
                        if $found_positional; then
                            echo "${COL_RED}Error:${COL_RESET} -A/--all must appear before path" >&2
                            exit 1
                        fi
                        if $found_bma; then
                            echo "${COL_RED}Error:${COL_RESET} -A/--all cannot be combined with -b/-c/-m/-a" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option -A/--all" >&2
                        fi
                        modify_btime=true; modify_mtime=true; modify_atime=true
                        has_options=true; found_A=true
                        ;;
                    -b|--birth|-c|--create)
                        if $found_positional; then
                            echo "${COL_RED}Error:${COL_RESET} flags must appear before path" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}Error:${COL_RESET} -b/-c/--birth/--create cannot be combined with -A/--all" >&2
                            exit 1
                        fi
                        if $modify_btime; then
                            echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option $arg" >&2
                        fi
                        modify_btime=true; has_options=true; found_bma=true
                        ;;
                    -m|--modify)
                        if $found_positional; then
                            echo "${COL_RED}Error:${COL_RESET} flags must appear before path" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}Error:${COL_RESET} -m/--modify cannot be combined with -A/--all" >&2
                            exit 1
                        fi
                        if $modify_mtime; then
                            echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option $arg" >&2
                        fi
                        modify_mtime=true; has_options=true; found_bma=true
                        ;;
                    -a|--access)
                        if $found_positional; then
                            echo "${COL_RED}Error:${COL_RESET} flags must appear before path" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}Error:${COL_RESET} -a/--access cannot be combined with -A/--all" >&2
                            exit 1
                        fi
                        if $modify_atime; then
                            echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option $arg" >&2
                        fi
                        modify_atime=true; has_options=true; found_bma=true
                        ;;
                    -V|--version)
                        echo "${COL_RED}Error:${COL_RESET} -V/--version cannot be combined with other arguments" >&2
                        exit 1
                        ;;
                    -h|--help)
                        echo "${COL_RED}Error:${COL_RESET} -h/--help cannot be combined with other arguments" >&2
                        exit 1
                        ;;
                    --)
                        no_more_opts=true
                        ;;
                    -b[bcma]*|-c[bcma]*|-m[bcma]*|-a[bcma]*)
                        if $found_positional; then
                            echo "${COL_RED}Error:${COL_RESET} flags must appear before path" >&2
                            exit 1
                        fi
                        if $found_A; then
                            echo "${COL_RED}Error:${COL_RESET} merged flags cannot be combined with -A/--all" >&2
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
                                *) echo "${COL_RED}Error:${COL_RESET} unknown option -$ch in $arg" >&2; exit 1 ;;
                            esac
                        done
                        if $has_b && $has_c; then
                            echo "${COL_YELLOW}Warning:${COL_RESET} -b and -c are aliases, cannot use both in $arg" >&2
                        fi
                        for ((i=0; i<${#flags}; i++)); do
                            ch="${flags:$i:1}"
                            case "$ch" in
                                b|c)
                                    if $modify_btime; then echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option -$ch in $arg" >&2; fi
                                    modify_btime=true
                                    ;;
                                m)
                                    if $modify_mtime; then echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option -m in $arg" >&2; fi
                                    modify_mtime=true
                                    ;;
                                a)
                                    if $modify_atime; then echo "${COL_YELLOW}Warning:${COL_RESET} duplicate option -a in $arg" >&2; fi
                                    modify_atime=true
                                    ;;
                            esac
                        done
                        has_options=true; found_bma=true
                        ;;
                    -*)
                        echo "${COL_RED}Error:${COL_RESET} unknown option: $arg" >&2
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
                echo "${COL_RED}Error:${COL_RESET} unexpected argument: ${parsed_args[3]}" >&2
                exit 1
            fi

            if [[ -z "$path" ]]; then
                echo "${COL_RED}Error:${COL_RESET} missing path argument" >&2
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
                echo "${COL_RED}Error:${COL_RESET} date argument required when using flags" >&2
                exit 1
            fi
            modify_mode "$path" "$date" "$time"
            exit $?
            ;;
    esac
fi

# ============ Main menu ============

main_menu() {
    echo "Select mode:"
    echo ""
    echo " [1] View mode"
    [[ -n "$setfile" ]] && echo " [2] Modify mode"
    echo " [0] Exit"
    echo ""
    local mode
    if [[ -n "$setfile" ]]; then
        read -erp "Choose mode (1/2): " mode || return 1
    else
        read -erp "Choose mode (1/0): " mode || return 1
    fi

    case "$mode" in
        1) view_mode || true ;;
        2) [[ -n "$setfile" ]] && modify_mode || true ;;
        0) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
}

# ============ TUI mode ============

find_setfile
if [[ -z "$setfile" ]]; then
    echo "${COL_YELLOW}Warning:${COL_RESET} SetFile not found, modify mode requires Xcode CLI tools"
    read -erp "Install now (Y/n): " _install_choice || true
    if [[ "$_install_choice" =~ ^[Yy]$ ]]; then
        echo "Installing Xcode Command Line Tools…"
        xcode-select --install
    fi
    echo ""
    echo "[View-only mode]"
fi
echo ""

while true; do
    main_menu || break
done
