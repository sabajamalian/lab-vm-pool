#!/usr/bin/env bash
set -e

# Azure VM User Configuration Script
# Configures users with sudo access on deployed VMs
# Prerequisites: az CLI logged in, sshpass installed, VMs deployed

CONFIG_FILE="${1:-./vm-users.local.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
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
    log_info "Install with: brew install sshpass (macOS) or apt install sshpass (Ubuntu)"
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
log_info "Admin Username: $ADMIN_USERNAME"

# Read users array
USERS_COUNT=$(jq '.users | length' "$CONFIG_FILE")

if [[ "$USERS_COUNT" -lt 1 ]]; then
    log_error "No users defined in config file"
    exit 1
fi

log_info "Users to configure: $USERS_COUNT"

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
    grep "^${vm_name}|" "$VM_IP_FILE" | cut -d'|' -f2
}

# SSH options for non-interactive connection
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Function to configure user on a VM
configure_user() {
    local vm_name=$1
    local username=$2
    local password=$3
    local vm_ip=$(get_vm_ip "$vm_name")

    if [[ -z "$vm_ip" ]]; then
        log_error "VM '$vm_name' not found or has no public IP"
        return 1
    fi

    log_info "Configuring user '$username' on VM '$vm_name' ($vm_ip)..."

    # Build the remote script to execute
    # This script is idempotent - it checks if user exists before creating
    local remote_script=$(cat <<EOF
#!/bin/bash
set -e

USERNAME="$username"
PASSWORD="$password"

# Check if user already exists
if id "\$USERNAME" &>/dev/null; then
    echo "User '\$USERNAME' already exists. Updating password and ensuring sudo access..."
    # Update password
    echo "\$USERNAME:\$PASSWORD" | sudo chpasswd
    # Ensure user is in sudo group
    sudo usermod -aG sudo "\$USERNAME"
    echo "User '\$USERNAME' updated successfully."
else
    echo "Creating user '\$USERNAME'..."
    # Create user with home directory and bash shell
    sudo useradd -m -s /bin/bash "\$USERNAME"
    # Set password
    echo "\$USERNAME:\$PASSWORD" | sudo chpasswd
    # Add to sudo group (standard Ubuntu sudo with password prompt)
    sudo usermod -aG sudo "\$USERNAME"
    echo "User '\$USERNAME' created successfully with sudo access."
fi

# Verify user setup
if id "\$USERNAME" &>/dev/null && groups "\$USERNAME" | grep -q sudo; then
    echo "SUCCESS: User '\$USERNAME' is configured with sudo access."
    exit 0
else
    echo "ERROR: Failed to configure user '\$USERNAME'"
    exit 1
fi
EOF
)

    # Execute remote script via SSH
    local result
    result=$(sshpass -p "$ADMIN_PASSWORD" ssh $SSH_OPTS "$ADMIN_USERNAME@$vm_ip" "$remote_script" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_info "  $result"
        return 0
    else
        log_error "  Failed to configure user on '$vm_name': $result"
        return 1
    fi
}

# Main configuration loop
log_info "Starting user configuration..."
echo ""

configured_count=0
skipped_count=0
failed_count=0

for i in $(seq 0 $((USERS_COUNT - 1))); do
    vm_name=$(jq -r ".users[$i].vm_name" "$CONFIG_FILE")
    username=$(jq -r ".users[$i].username" "$CONFIG_FILE")
    password=$(jq -r ".users[$i].password" "$CONFIG_FILE")

    # Validate user entry
    if [[ -z "$vm_name" || "$vm_name" == "null" ]]; then
        log_warn "Skipping entry $i: vm_name is missing"
        ((skipped_count++))
        continue
    fi

    if [[ -z "$username" || "$username" == "null" ]]; then
        log_warn "Skipping entry $i: username is missing"
        ((skipped_count++))
        continue
    fi

    if [[ -z "$password" || "$password" == "null" ]]; then
        log_warn "Skipping entry $i: password is missing"
        ((skipped_count++))
        continue
    fi

    if configure_user "$vm_name" "$username" "$password"; then
        ((configured_count++))
    else
        ((failed_count++))
    fi
done

# Summary
echo ""
log_info "========== Configuration Summary =========="
log_info "Total users in config: $USERS_COUNT"
log_info "Users configured: $configured_count"
if [[ $skipped_count -gt 0 ]]; then
    log_warn "Users skipped (invalid config): $skipped_count"
fi
if [[ $failed_count -gt 0 ]]; then
    log_error "Users failed: $failed_count"
fi
log_info "==========================================="

# Exit with error if any users failed
if [[ $failed_count -gt 0 ]]; then
    exit 1
fi

exit 0
