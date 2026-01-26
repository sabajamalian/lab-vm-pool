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

## VM User Configuration

After deploying VMs, you can configure student/user accounts with sudo access using the `configure-vms.sh` script.

### Prerequisites

- **sshpass** installed (`brew install hudochenkov/sshpass/sshpass` on macOS or `apt install sshpass` on Ubuntu)
- VMs deployed and running with public IPs

### Quick Start

1. **Copy the example user config file:**
   ```bash
   cp vm-users.example.json vm-users.local.json
   ```

2. **Edit the config file with your user definitions:**
   ```json
   {
     "deployment_config": "./.cs318.sp26.local.json",
     "users": [
       {
         "vm_name": "vm-001",
         "username": "student1",
         "password": "StudentP@ss1!"
       },
       {
         "vm_name": "vm-002",
         "username": "student2",
         "password": "StudentP@ss2!"
       }
     ]
   }
   ```

3. **Run the configuration script:**
   ```bash
   ./configure-vms.sh vm-users.local.json
   ```

### User Configuration Options

| Parameter | Required | Description |
|-----------|----------|-------------|
| `deployment_config` | Yes | Path to the VM deployment config (contains admin credentials) |
| `users` | Yes | Array of user definitions |
| `users[].vm_name` | Yes | Name of the target VM (e.g., `vm-001`) |
| `users[].username` | Yes | Username to create |
| `users[].password` | Yes | Password for the user |

### Idempotent Behavior

The configuration script is idempotent:
- If a user already exists, their password will be updated and sudo access verified
- Running the script multiple times is safe

```
[INFO] Configuring user 'student1' on VM 'vm-001' (20.1.2.3)...
[INFO]   User 'student1' already exists. Updating password and ensuring sudo access...
[INFO]   SUCCESS: User 'student1' is configured with sudo access.
```

### Sudo Access

Users created by this script are added to the `sudo` group, which provides standard Ubuntu sudo behavior:
- Users can run commands with `sudo`
- Password is required for sudo commands
- Suitable for educational environments where students need to practice Linux administration

## Security Notes

⚠️ **Important:** The `*.local.json` config files contain sensitive credentials and are git-ignored by default. Never commit these files to version control.

For production use, consider:
- Using Azure Key Vault for secrets
- Using SSH keys instead of passwords
- Implementing managed identities
