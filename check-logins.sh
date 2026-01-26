#!/usr/bin/env bash
set -e

# Set locale to handle byte sequences properly
export LC_ALL=C
export LANG=C

# Azure VM User Login Check Script
# Reports last login time for users on deployed VMs
# Prerequisites: az CLI logged in, sshpass installed, VMs deployed

CONFIG_FILE="${1:-./vm-users.local.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    log_info "Please create a config file based on vm-users.example.json"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed. Please install jq."
    exit 1
fi

# Check if sshpass is installed
if ! command -v sshpass &> /dev/null; then
    log_error "sshpass is required but not installed."
    log_info "Install with: brew install hudochenkov/sshpass/sshpass (macOS) or apt install sshpass (Ubuntu)"
    exit 1
fi

# Check if az CLI is logged in
if ! az account show &> /dev/null; then
    log_error "Azure CLI is not logged in. Please run 'az login' first."
    exit 1
fi

# Read deployment config path from user config
DEPLOYMENT_CONFIG=$(jq -r '.deployment_config' "$CONFIG_FILE")

if [[ -z "$DEPLOYMENT_CONFIG" || "$DEPLOYMENT_CONFIG" == "null" ]]; then
    log_error "deployment_config is required in config file"
    exit 1
fi

# Resolve relative path
if [[ ! "$DEPLOYMENT_CONFIG" = /* ]]; then
    DEPLOYMENT_CONFIG="$(dirname "$CONFIG_FILE")/$DEPLOYMENT_CONFIG"
fi

if [[ ! -f "$DEPLOYMENT_CONFIG" ]]; then
    log_error "Deployment config file not found: $DEPLOYMENT_CONFIG"
    exit 1
fi

# Read admin credentials and resource group from deployment config
ADMIN_USERNAME=$(jq -r '.admin_username' "$DEPLOYMENT_CONFIG")
ADMIN_PASSWORD=$(jq -r '.admin_password' "$DEPLOYMENT_CONFIG")
RESOURCE_GROUP=$(jq -r '.resource_group' "$DEPLOYMENT_CONFIG")

if [[ -z "$ADMIN_USERNAME" || "$ADMIN_USERNAME" == "null" ]]; then
    log_error "admin_username not found in deployment config"
    exit 1
fi

if [[ -z "$ADMIN_PASSWORD" || "$ADMIN_PASSWORD" == "null" ]]; then
    log_error "admin_password not found in deployment config"
    exit 1
fi

if [[ -z "$RESOURCE_GROUP" || "$RESOURCE_GROUP" == "null" ]]; then
    log_error "resource_group not found in deployment config"
    exit 1
fi

log_info "Configuration loaded from: $CONFIG_FILE"
log_info "Deployment config: $DEPLOYMENT_CONFIG"
log_info "Resource Group: $RESOURCE_GROUP"

# Read users array
USERS_COUNT=$(jq '.users | length' "$CONFIG_FILE")

if [[ "$USERS_COUNT" -lt 1 ]]; then
    log_error "No users defined in config file"
    exit 1
fi

log_info "Users to check: $USERS_COUNT"

# Fetch VM IP addresses from Azure
log_info "Fetching VM IP addresses from Azure..."

# Get all VM IPs in the resource group and store in temp file
VM_IP_FILE=$(mktemp)
trap "rm -f $VM_IP_FILE" EXIT

vm_ip_data=$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" -o json 2>/dev/null)

if [[ -z "$vm_ip_data" || "$vm_ip_data" == "[]" ]]; then
    log_error "No VMs found in resource group '$RESOURCE_GROUP'"
    exit 1
fi

# Parse VM IPs into temp file (format: vm_name|ip)
echo "$vm_ip_data" | jq -r '.[] | "\(.virtualMachine.name)|\(.virtualMachine.network.publicIpAddresses[0].ipAddress)"' > "$VM_IP_FILE"

vm_count=$(wc -l < "$VM_IP_FILE" | tr -d ' ')
log_info "Found $vm_count VMs with public IPs"

# Function to get VM IP by name
get_vm_ip() {
    local vm_name=$1
    grep "^${vm_name}|" "$VM_IP_FILE" 2>/dev/null | cut -d'|' -f2
}

# SSH options for non-interactive connection
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Function to check user last login on a VM
check_user_login() {
    local vm_name=$1
    local username=$2
    local vm_ip=$(get_vm_ip "$vm_name")

    if [[ -z "$vm_ip" ]]; then
        echo "ERROR|VM '$vm_name' not found or has no public IP|"
        return 1
    fi

    # Build the remote script to check last login and command history
    local remote_script=$(cat <<'EOF'
#!/bin/bash
USERNAME="$1"

# Check if user exists
if ! id "$USERNAME" &>/dev/null; then
    echo "USER_NOT_FOUND|User does not exist|"
    exit 0
fi

# Get last login info
login_status=""
login_message=""

# Try lastlog first (more reliable for never-logged-in users)
lastlog_output=$(lastlog -u "$USERNAME" 2>/dev/null | tail -1)

if echo "$lastlog_output" | grep -q "Never logged in"; then
    login_status="NEVER"
    login_message="Never logged in"
else
    # Try last command for more detailed info
    last_output=$(last -n 1 "$USERNAME" 2>/dev/null | head -1)

    if [[ -z "$last_output" || "$last_output" == *"wtmp begins"* ]]; then
        # No login records in wtmp, check lastlog
        if [[ -n "$lastlog_output" ]]; then
            latest=$(echo "$lastlog_output" | awk '{$1=""; $2=""; $3=""; print $0}' | sed 's/^[[:space:]]*//')
            if [[ -n "$latest" && "$latest" != *"Never"* ]]; then
                login_status="LOGGED_IN"
                login_message="$latest"
            else
                login_status="NEVER"
                login_message="Never logged in"
            fi
        else
            login_status="NEVER"
            login_message="Never logged in"
        fi
    else
        if echo "$last_output" | grep -q "still logged in"; then
            login_time=$(echo "$last_output" | awk '{print $4, $5, $6, $7}')
            login_status="ACTIVE"
            login_message="Currently logged in (since $login_time)"
        else
            login_time=$(echo "$last_output" | awk '{print $4, $5, $6, $7}')
            login_status="LOGGED_IN"
            login_message="Last login: $login_time"
        fi
    fi
fi

# Get last 10 commands from user's bash history
user_home=$(eval echo "~$USERNAME")
history_file="$user_home/.bash_history"
commands=""

if [[ -f "$history_file" && -r "$history_file" ]]; then
    # Read last 10 commands, escape pipe characters for our delimiter
    commands=$(sudo tail -n 10 "$history_file" 2>/dev/null | sed 's/|/\\|/g' | tr '\n' '§' | sed 's/§$//')
elif sudo test -f "$history_file" 2>/dev/null; then
    commands=$(sudo tail -n 10 "$history_file" 2>/dev/null | sed 's/|/\\|/g' | tr '\n' '§' | sed 's/§$//')
else
    commands="NO_HISTORY"
fi

echo "${login_status}|${login_message}|${commands}"
EOF
)

    # Execute remote script via SSH
    local result
    result=$(sshpass -p "$ADMIN_PASSWORD" ssh $SSH_OPTS "$ADMIN_USERNAME@$vm_ip" "bash -s" "$username" <<< "$remote_script" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        echo "ERROR|SSH connection failed: $result|"
        return 1
    fi
}

# Print header
echo ""
printf "${CYAN}%-12s %-20s %-15s %s${NC}\n" "VM" "USERNAME" "STATUS" "LAST LOGIN"
printf "${CYAN}%-12s %-20s %-15s %s${NC}\n" "------------" "--------------------" "---------------" "--------------------------------"

# Main check loop
success_count=0
failed_count=0
never_logged_count=0
active_count=0

for i in $(seq 0 $((USERS_COUNT - 1))); do
    vm_name=$(jq -r ".users[$i].vm_name" "$CONFIG_FILE")
    username=$(jq -r ".users[$i].username" "$CONFIG_FILE")

    # Validate user entry
    if [[ -z "$vm_name" || "$vm_name" == "null" || -z "$username" || "$username" == "null" ]]; then
        continue
    fi

    result=$(check_user_login "$vm_name" "$username")
    # Use awk instead of cut to avoid byte sequence issues
    status=$(echo "$result" | awk -F'|' '{print $1}')
    message=$(echo "$result" | awk -F'|' '{print $2}')
    commands=$(echo "$result" | awk -F'|' '{print $3}')

    case "$status" in
        "ACTIVE")
            printf "${GREEN}%-12s${NC} %-20s ${GREEN}%-15s${NC} %s\n" "$vm_name" "$username" "ACTIVE" "$message"
            ((active_count++))
            ((success_count++))
            ;;
        "LOGGED_IN")
            printf "%-12s %-20s ${BLUE}%-15s${NC} %s\n" "$vm_name" "$username" "LOGGED IN" "$message"
            ((success_count++))
            ;;
        "NEVER")
            printf "%-12s %-20s ${YELLOW}%-15s${NC} %s\n" "$vm_name" "$username" "NEVER" "$message"
            ((never_logged_count++))
            ((success_count++))
            ;;
        "USER_NOT_FOUND")
            printf "%-12s %-20s ${RED}%-15s${NC} %s\n" "$vm_name" "$username" "NOT FOUND" "$message"
            ((failed_count++))
            ;;
        "ERROR")
            printf "%-12s %-20s ${RED}%-15s${NC} %s\n" "$vm_name" "$username" "ERROR" "$message"
            ((failed_count++))
            ;;
        *)
            printf "%-12s %-20s ${YELLOW}%-15s${NC} %s\n" "$vm_name" "$username" "UNKNOWN" "$result"
            ((failed_count++))
            ;;
    esac

    # Print command history if available
    if [[ -n "$commands" && "$commands" != "NO_HISTORY" && "$status" != "ERROR" && "$status" != "USER_NOT_FOUND" ]]; then
        printf "             ${CYAN}Last 10 commands:${NC}\n"
        # Split by § delimiter and print each command
        echo "$commands" | tr '§' '\n' | while IFS= read -r cmd; do
            if [[ -n "$cmd" ]]; then
                # Unescape pipe characters
                cmd=$(echo "$cmd" | sed 's/\\|/|/g')
                printf "               ${BLUE}→${NC} %s\n" "$cmd"
            fi
        done
    elif [[ "$commands" == "NO_HISTORY" && "$status" != "ERROR" && "$status" != "USER_NOT_FOUND" ]]; then
        printf "             ${YELLOW}No command history found${NC}\n"
    fi
    echo ""
done

# Summary
echo ""
log_info "========== Login Check Summary =========="
log_info "Total users checked: $USERS_COUNT"
log_info "Currently active: $active_count"
log_info "Previously logged in: $((success_count - active_count - never_logged_count))"
log_info "Never logged in: $never_logged_count"
if [[ $failed_count -gt 0 ]]; then
    log_error "Errors: $failed_count"
fi
log_info "========================================="

exit 0
