#!/bin/bash
# union_remotes_cleanup.sh
#
# This script scans your rclone config for union-type remotes named
# one of: media, documents, photos, binaries, apps, backups.
#
# For each such union remote, it extracts its upstreams, identifies the local branch
# (a token starting with “/”) and the backup remotes.
#
# It then uses the real local path (from the local token) to check free space (via df)
# and usage (via du). If the partition free space is ≤10% and usage exceeds a category‑specific
# maximum threshold, it lists files (oldest first) and, for each file, checks that:
#   • Deletion won’t drop usage below the category’s minimum threshold.
#   • The file is backed up on all backup remotes. If not, it forces a backup (rclone copyto)
#     and rechecks before proceeding.
#
# Only after these checks does it delete (or simulate deletion in DRY_RUN mode) the file.
#
# USAGE:
#   ./union_remotes_cleanup.sh
#
# IMPORTANT: Test in DRY_RUN mode before allowing deletions!

####################
# CONFIGURATION
####################

# Allowed union remote names (each corresponds to a category)
ALLOWED_UNION_REMOTES=("media" "documents" "photos" "binaries" "apps" "backups")

# Category-specific thresholds (in MB) – adjust as needed.
declare -A MIN_SPACE
declare -A MAX_SPACE
MIN_SPACE["media"]=100000    
MAX_SPACE["media"]=400000  

MIN_SPACE["documents"]=10000   
MAX_SPACE["documents"]=50000  

MIN_SPACE["photos"]=75000    
MAX_SPACE["photos"]= 150000

MIN_SPACE["binaries"]=10000  
MAX_SPACE["binaries"]=100000    

MIN_SPACE["apps"]=90000      
MAX_SPACE["apps"]=100000    

MIN_SPACE["backups"]=10000   
MAX_SPACE["backups"]=100000      

# Set DRY_RUN=1 to simulate; set DRY_RUN=0 to perform actual deletions.
DRY_RUN=1

####################
# Logging & Signal Handling
####################

log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

trap 'log_warn "Script interrupted. Exiting."; exit 1' SIGINT SIGTERM

####################
# Helper Functions
####################

# extract_upstreams:
# Reads the rclone config file and extracts the upstreams line from a given union remote section.
extract_upstreams() {
    local union_title="$1"
    local config_file
    config_file=$(rclone config file 2>/dev/null | tail -n 1)
    if [ ! -f "$config_file" ]; then
        log_error "Rclone config file not found at [$config_file]. Exiting."
        exit 1
    fi
    local line
    line=$(awk '/^\['"$union_title"'\]/{flag=1} flag && /^upstreams[[:space:]]*=/{print; exit}' "$config_file")
    if [ -z "$line" ]; then
        log_error "Could not find 'upstreams' for union remote [$union_title] in $config_file."
        exit 1
    fi
    local upstreams
    upstreams=$(echo "$line" | cut -d'=' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    echo "$upstreams"
}

# parse_upstreams:
# Splits an upstreams string into a local token (must begin with "/") and backup tokens.
parse_upstreams() {
    local upstreams_str="$1"
    local local_tok=""
    local backups=()
    read -ra tokens <<< "$upstreams_str"
    for token in "${tokens[@]}"; do
        if [[ "$token" == /* ]]; then
            if [ -n "$local_tok" ]; then
                log_error "Multiple local tokens found in upstreams: [$local_tok] and [$token]. Exiting."
                exit 1
            fi
            local_tok="$token"
        else
            backups+=("$token")
        fi
    done
    if [ -z "$local_tok" ]; then
        log_error "No local upstream found in upstreams: [$upstreams_str]. Exiting."
        exit 1
    fi
    # Output: first line is the local token; subsequent lines are backup tokens.
    echo "$local_tok"
    for b in "${backups[@]}"; do
        echo "$b"
    done
}

# check_free_space:
# Uses df on the partition containing the given directory to determine free space.
# Exits if free space is more than 10%.
check_free_space() {
    local local_dir="$1"
    local df_out
    df_out=$(df -P "$local_dir" 2>/dev/null | tail -n 1)
    if [ -z "$df_out" ]; then
        log_error "df command failed on [$local_dir]. Exiting."
        exit 1
    fi
    read -r _ blocks used available capacity mountpoint <<< "$df_out"
    if [ -z "$blocks" ] || [ "$blocks" -eq 0 ]; then
        log_error "Unable to determine blocks for [$local_dir]. Exiting."
        exit 1
    fi
    local free_percent=$(( 100 * available / blocks ))
    log_info "Free space on partition [$local_dir]: ${free_percent}%"
    if (( free_percent > 10 )); then
        log_info "More than 10% free space available. Skipping cleanup for [$local_dir]."
        return 1
    fi
    return 0
}

# get_usage_category:
# Returns the disk usage (in MB) for a given directory.
get_usage_category() {
    local local_dir="$1"
    local usage
    usage=$(du -sm "$local_dir" 2>/dev/null | cut -f1)
    if [[ -z "$usage" ]]; then usage=0; fi
    echo "$usage"
}

# list_files_category:
# Lists files in a given directory sorted by modification time (oldest first).
list_files_category() {
    local local_dir="$1"
    if [ ! -d "$local_dir" ]; then
        log_warn "Directory [$local_dir] does not exist. Skipping."
        return
    fi
    find "$local_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-
}

# check_backup_for_file:
# For a given file (relative to the local directory) in a given category,
# verifies that the file exists on all backup remotes.
# If not, it forces a backup using rclone copyto.
check_backup_for_file() {
    local category="$1"
    local file_rel="$2"
    local local_file="$3"  # full path to the file
    for backup in "${BACKUP_REMOTES_ARRAY[@]}"; do
        local remote_path
        # Build the remote path. If a union relative is defined, use it.
        if [ -n "$UNION_RELATIVE" ]; then
            remote_path="${backup}${UNION_RELATIVE}/${category}/${file_rel}"
        else
            remote_path="${backup}${category}/${file_rel}"
        fi
        if ! rclone size "$remote_path" 2>/dev/null | grep -q "Total size:"; then
            log_warn "File '$file_rel' not found on backup remote at [$remote_path]. Forcing backup..."
            if (( DRY_RUN )); then
                log_info "[DRY RUN] Would force backup of '$local_file' to '$remote_path'."
            else
                rclone copyto "$local_file" "$remote_path"
                if [ $? -ne 0 ]; then
                    log_error "rclone copyto failed for '$local_file' to '$remote_path'."
                    return 1
                fi
            fi
            if ! rclone size "$remote_path" 2>/dev/null | grep -q "Total size:"; then
                log_error "Forced backup still missing for '$file_rel' on remote [$remote_path]."
                return 1
            else
                log_info "Forced backup succeeded for '$file_rel' on remote [$remote_path]."
            fi
        fi
    done
    return 0
}

# cleanup_category:
# For a given category (union remote) and its corresponding local directory,
# if the usage exceeds MAX_SPACE, iterates over files (oldest first) and deletes them
# until usage drops below MAX_SPACE, ensuring deletion does not drop usage below MIN_SPACE,
# and that each file is backed up (forcing backup if necessary).
cleanup_category() {
    local category="$1"
    local local_dir="$2"
    local current_usage min_threshold max_threshold file file_rel file_size

    current_usage=$(get_usage_category "$local_dir")
    min_threshold=${MIN_SPACE[$category]}
    max_threshold=${MAX_SPACE[$category]}
    log_info "Processing category: [$category] at local directory [$local_dir]"
    log_info "Current usage: ${current_usage} MB (Min: ${min_threshold} MB, Max: ${max_threshold} MB)"
    
    if (( current_usage <= max_threshold )); then
        log_info "Usage for [$category] is within limits. No cleanup needed."
        return
    fi
    
    log_info "Usage for [$category] exceeds maximum threshold. Initiating cleanup..."
    
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        file_rel="${file#$local_dir/}"
        file_size=$(du -sm "$file" 2>/dev/null | cut -f1)
        if [ -z "$file_size" ]; then
            log_warn "Unable to determine size for [$file]. Skipping."
            continue
        fi

        current_usage=$(get_usage_category "$local_dir")
        if (( current_usage <= max_threshold )); then
            log_info "Usage for [$category] is now ${current_usage} MB, below maximum threshold. Stopping cleanup."
            break
        fi
        
        local potential_usage=$(( current_usage - file_size ))
        if (( potential_usage < min_threshold )); then
            log_warn "Skipping '$file_rel': deletion would drop usage to ${potential_usage} MB, below minimum threshold of ${min_threshold} MB."
            continue
        fi
        
        if check_backup_for_file "$category" "$file_rel" "$file"; then
            log_info "File '$file_rel' is backed up on all backup remotes. Eligible for deletion."
            if (( DRY_RUN )); then
                log_info "[DRY RUN] Would delete $file (size: ${file_size} MB)."
            else
                rm "$file"
                if [ $? -eq 0 ]; then
                    log_info "Deleted $file (size: ${file_size} MB)."
                else
                    log_error "Failed to delete $file. Skipping."
                fi
            fi
        else
            log_warn "File '$file_rel' is not fully backed up. Skipping deletion."
        fi
    done < <(list_files_category "$local_dir")
    
    current_usage=$(get_usage_category "$local_dir")
    log_info "Final usage for [$category]: ${current_usage} MB"
}

####################
# MAIN EXECUTION
####################

# Get the rclone config file path.
CONFIG_FILE=$(rclone config file 2>/dev/null | tail -n 1)
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Rclone config file not found at [$CONFIG_FILE]. Exiting."
    exit 1
fi

log_info "Scanning rclone config [$CONFIG_FILE] for allowed union remotes..."

# For each allowed union remote, check if it exists in the config and is of type union.
for category in "${ALLOWED_UNION_REMOTES[@]}"; do
    if ! grep -q "^\[$category\]" "$CONFIG_FILE"; then
        log_warn "Union remote section [$category] not found in config. Skipping."
        continue
    fi
    # Verify that the section is of type union.
    if ! awk '/^\['"$category"'\]/{flag=1} flag && /^type[[:space:]]*=/{print; exit}' "$CONFIG_FILE" | grep -qi "union"; then
        log_warn "Section [$category] is not of type union. Skipping."
        continue
    fi
    
    log_info "Processing union remote [$category]..."
    upstreams_extracted=$(extract_upstreams "$category")
    if [ -z "$upstreams_extracted" ]; then
        log_error "Failed to extract upstreams for [$category]. Skipping."
        continue
    fi
    log_info "Extracted upstreams for [$category]: $upstreams_extracted"
    
    # Parse tokens.
    mapfile -t parsed_tokens < <(parse_upstreams "$upstreams_extracted")
    LOCAL_TOKEN="${parsed_tokens[0]}"
    if [ -z "$LOCAL_TOKEN" ]; then
        log_error "Local token for [$category] is empty. Skipping."
        continue
    fi
    # Build backup remotes array from token 2 onward.
    BACKUP_REMOTES_ARRAY=()
    for ((i=1; i < ${#parsed_tokens[@]}; i++)); do
        BACKUP_REMOTES_ARRAY+=("${parsed_tokens[$i]}")
    done
    if [ ${#BACKUP_REMOTES_ARRAY[@]} -eq 0 ]; then
        log_error "No backup remotes found in union remote [$category]. Skipping."
        continue
    fi
    
    # Extract the local path from LOCAL_TOKEN (everything before the colon).
    LOCAL_PATH=$(echo "$LOCAL_TOKEN" | cut -d':' -f1)
    if [ ! -d "$LOCAL_PATH" ]; then
        log_error "Local path [$LOCAL_PATH] for union remote [$category] does not exist or is not a directory. Skipping."
        continue
    fi
    
    log_info "For union remote [$category]:"
    log_info "  Local path: $LOCAL_PATH"
    log_info "  Backup remotes: ${BACKUP_REMOTES_ARRAY[*]}"
    
    # Check free space on the partition containing LOCAL_PATH.
    if ! check_free_space "$LOCAL_PATH"; then
        log_info "Skipping cleanup for [$category] due to sufficient free space."
        continue
    fi
    
    # Process cleanup for this category.
    cleanup_category "$category" "$LOCAL_PATH"
done

log_info "All eligible union remotes processed. Cleanup complete."
