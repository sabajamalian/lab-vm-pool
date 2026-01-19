# Azure VM Pool Deployment

A shell script to deploy N number of Azure virtual machines using basic (password) authentication.

## Prerequisites

- **Azure CLI** (`az`) installed and logged in
- **jq** installed for JSON parsing (`brew install jq` on macOS)
- An Azure subscription selected
- A resource group already created

## Quick Start

1. **Copy the example config file:**
   ```bash
   cp vm-config.example.json vm-config.local.json
   ```

2. **Edit the config file with your settings:**
   ```bash
   # Edit vm-config.local.json with your values
   ```

3. **Run the deployment script:**
   ```bash
   ./deploy-vms.sh
   ```

   Or specify a custom config file:
   ```bash
   ./deploy-vms.sh /path/to/my-config.json
   ```

## Configuration Options

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `resource_group` | Yes | Name of the existing Azure resource group | - |
| `location` | Yes | Azure region (e.g., `eastus`, `westus2`) | - |
| `vm_count` | Yes | Number of VMs to deploy | - |
| `vm_name_prefix` | Yes | Prefix for VM names (e.g., `lab-vm` → `lab-vm-001`) | - |
| `vm_size` | Yes | Azure VM size (e.g., `Standard_B2s`) | - |
| `image` | Yes | VM image (e.g., `Ubuntu2204`, `Win2022Datacenter`) | - |
| `admin_username` | Yes | Administrator username | - |
| `admin_password` | Yes | Administrator password | - |
| `os_disk_size_gb` | No | OS disk size in GB | `30` |
| `vnet_name` | No | Existing VNet name | Auto-created |
| `subnet_name` | No | Existing subnet name | Auto-created |
| `nsg_name` | No | Existing NSG name | Auto-created |
| `public_ip` | No | Assign public IP (`true`/`false`) | `true` |
| `tags` | No | Resource tags as key-value pairs | `{}` |

## Example Configuration

```json
{
  "resource_group": "my-lab-rg",
  "location": "eastus",
  "vm_count": 5,
  "vm_name_prefix": "lab-vm",
  "vm_size": "Standard_B2s",
  "image": "Ubuntu2204",
  "admin_username": "labadmin",
  "admin_password": "SecureP@ssw0rd123!",
  "os_disk_size_gb": 64,
  "public_ip": true,
  "tags": {
    "environment": "lab",
    "project": "training"
  }
}
```

## Common Azure VM Images

- `Ubuntu2204` - Ubuntu 22.04 LTS
- `Ubuntu2004` - Ubuntu 20.04 LTS
- `Debian11` - Debian 11
- `CentOS85Gen2` - CentOS 8.5
- `Win2022Datacenter` - Windows Server 2022
- `Win2019Datacenter` - Windows Server 2019

## Common Azure VM Sizes

- `Standard_B1s` - 1 vCPU, 1 GB RAM (burstable)
- `Standard_B2s` - 2 vCPU, 4 GB RAM (burstable)
- `Standard_D2s_v3` - 2 vCPU, 8 GB RAM
- `Standard_D4s_v3` - 4 vCPU, 16 GB RAM

## Idempotent Behavior

The script is idempotent. If a VM with the same name already exists, its creation will be skipped:

```
[WARN] VM 'lab-vm-001' already exists. Skipping...
[INFO] Creating VM: lab-vm-002
```

## Security Notes

⚠️ **Important:** The `vm-config.local.json` file contains sensitive credentials and is git-ignored by default. Never commit this file to version control.

For production use, consider:
- Using Azure Key Vault for secrets
- Using SSH keys instead of passwords
- Implementing managed identities
