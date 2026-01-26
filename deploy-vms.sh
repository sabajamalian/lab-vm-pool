#!/bin/bash
set -e

# Azure VM Deployment Script
# Deploys N virtual machines using basic authentication
# Prerequisites: az CLI logged in, subscription selected, resource group exists

CONFIG_FILE="${1:-./vm-config.local.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
    log_info "Please create a config file based on vm-config.example.json"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed. Please install jq."
    exit 1
fi

# Check if az CLI is logged in
if ! az account show &> /dev/null; then
    log_error "Azure CLI is not logged in. Please run 'az login' first."
    exit 1
fi

# Read configuration
RESOURCE_GROUP=$(jq -r '.resource_group' "$CONFIG_FILE")
VM_NAME_PREFIX=$(jq -r '.vm_name_prefix' "$CONFIG_FILE")
VM_SIZE=$(jq -r '.vm_size' "$CONFIG_FILE")
IMAGE=$(jq -r '.image' "$CONFIG_FILE")
ADMIN_USERNAME=$(jq -r '.admin_username' "$CONFIG_FILE")
ADMIN_PASSWORD=$(jq -r '.admin_password' "$CONFIG_FILE")
OS_DISK_SIZE=$(jq -r '.os_disk_size_gb // 30' "$CONFIG_FILE")
VNET_NAME=$(jq -r '.vnet_name // ""' "$CONFIG_FILE")
SUBNET_NAME=$(jq -r '.subnet_name // ""' "$CONFIG_FILE")
NSG_NAME=$(jq -r '.nsg_name // ""' "$CONFIG_FILE")
PUBLIC_IP=$(jq -r '.public_ip // true' "$CONFIG_FILE")
TAGS=$(jq -r '.tags // {}' "$CONFIG_FILE")

# Read locations array
LOCATIONS_COUNT=$(jq '.locations | length' "$CONFIG_FILE")

# Validate required parameters
if [[ -z "$RESOURCE_GROUP" || "$RESOURCE_GROUP" == "null" ]]; then
    log_error "resource_group is required in config file"
    exit 1
fi

if [[ -z "$LOCATIONS_COUNT" || "$LOCATIONS_COUNT" == "null" || "$LOCATIONS_COUNT" -lt 1 ]]; then
    log_error "locations array must contain at least one location"
    exit 1
fi

if [[ -z "$VM_NAME_PREFIX" || "$VM_NAME_PREFIX" == "null" ]]; then
    log_error "vm_name_prefix is required in config file"
    exit 1
fi

if [[ -z "$ADMIN_USERNAME" || "$ADMIN_USERNAME" == "null" ]]; then
    log_error "admin_username is required in config file"
    exit 1
fi

if [[ -z "$ADMIN_PASSWORD" || "$ADMIN_PASSWORD" == "null" ]]; then
    log_error "admin_password is required in config file"
    exit 1
fi

# Calculate total VM count across all locations
TOTAL_VM_COUNT=0
for i in $(seq 0 $((LOCATIONS_COUNT - 1))); do
    count=$(jq -r ".locations[$i].vm_count" "$CONFIG_FILE")
    TOTAL_VM_COUNT=$((TOTAL_VM_COUNT + count))
done

log_info "Configuration loaded from: $CONFIG_FILE"
log_info "Resource Group: $RESOURCE_GROUP"
log_info "Locations: $LOCATIONS_COUNT"
for i in $(seq 0 $((LOCATIONS_COUNT - 1))); do
    loc_name=$(jq -r ".locations[$i].name" "$CONFIG_FILE")
    loc_count=$(jq -r ".locations[$i].vm_count" "$CONFIG_FILE")
    log_info "  - $loc_name: $loc_count VM(s)"
done
log_info "Total VM Count: $TOTAL_VM_COUNT"
log_info "VM Name Prefix: $VM_NAME_PREFIX"
log_info "VM Size: $VM_SIZE"
log_info "Image: $IMAGE"

# Check if resource group exists
if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    log_error "Resource group '$RESOURCE_GROUP' does not exist"
    exit 1
fi

# Function to check if VM exists
vm_exists() {
    local vm_name=$1
    az vm show --resource-group "$RESOURCE_GROUP" --name "$vm_name" &> /dev/null
    return $?
}

# Function to create a VM
create_vm() {
    local vm_name=$1
    local vm_index=$2
    local location=$3

    log_info "Creating VM: $vm_name in $location"

    # Build the az vm create command
    local cmd="az vm create \
        --resource-group \"$RESOURCE_GROUP\" \
        --name \"$vm_name\" \
        --location \"$location\" \
        --image \"$IMAGE\" \
        --size \"$VM_SIZE\" \
        --admin-username \"$ADMIN_USERNAME\" \
        --admin-password \"$ADMIN_PASSWORD\" \
        --authentication-type password \
        --os-disk-size-gb \"$OS_DISK_SIZE\""

    # Add optional VNet/Subnet
    if [[ -n "$VNET_NAME" && "$VNET_NAME" != "null" && -n "$SUBNET_NAME" && "$SUBNET_NAME" != "null" ]]; then
        cmd="$cmd --vnet-name \"$VNET_NAME\" --subnet \"$SUBNET_NAME\""
    fi

    # Add optional NSG
    if [[ -n "$NSG_NAME" && "$NSG_NAME" != "null" ]]; then
        cmd="$cmd --nsg \"$NSG_NAME\""
    fi

    # Add public IP option
    if [[ "$PUBLIC_IP" == "false" ]]; then
        cmd="$cmd --public-ip-address \"\""
    fi

    # Add tags if specified
    if [[ -n "$TAGS" && "$TAGS" != "{}" && "$TAGS" != "null" ]]; then
        local tags_string=$(echo "$TAGS" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")')
        if [[ -n "$tags_string" ]]; then
            cmd="$cmd --tags $tags_string"
        fi
    fi

    # Execute the command
    eval "$cmd"

    if [[ $? -eq 0 ]]; then
        log_info "Successfully created VM: $vm_name"
    else
        log_error "Failed to create VM: $vm_name"
        return 1
    fi
}

# Main deployment loop
log_info "Starting deployment of $TOTAL_VM_COUNT VM(s) across $LOCATIONS_COUNT location(s)..."

created_count=0
skipped_count=0
failed_count=0
global_vm_index=1

for loc_idx in $(seq 0 $((LOCATIONS_COUNT - 1))); do
    LOCATION=$(jq -r ".locations[$loc_idx].name" "$CONFIG_FILE")
    VM_COUNT=$(jq -r ".locations[$loc_idx].vm_count" "$CONFIG_FILE")

    log_info "Processing location: $LOCATION ($VM_COUNT VMs)"

    for i in $(seq 1 "$VM_COUNT"); do
        vm_name="${VM_NAME_PREFIX}-$(printf '%03d' $global_vm_index)"

        if vm_exists "$vm_name"; then
            log_warn "VM '$vm_name' already exists. Skipping..."
            ((skipped_count++))
        else
            if create_vm "$vm_name" "$global_vm_index" "$LOCATION"; then
                ((created_count++))
            else
                ((failed_count++))
            fi
        fi
        ((global_vm_index++))
    done
done

# Summary
echo ""
log_info "========== Deployment Summary =========="
log_info "Total VMs requested: $TOTAL_VM_COUNT"
log_info "Locations: $LOCATIONS_COUNT"
log_info "VMs created: $created_count"
log_info "VMs skipped (already exist): $skipped_count"
if [[ $failed_count -gt 0 ]]; then
    log_error "VMs failed: $failed_count"
fi
log_info "========================================"

# Exit with error if any VMs failed
if [[ $failed_count -gt 0 ]]; then
    exit 1
fi

exit 0
