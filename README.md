<p align="center"><img src="https://raw.githubusercontent.com/talder/xyOps-MSSQL-Information/refs/heads/main/logo.png" height="108" alt="Logo"/></p>
<h1 align="center">MSSQL Information</h1>

# xyOps MSSQL Information Plugin

[![Version](https://img.shields.io/badge/version-1.0.2-blue.svg)](https://github.com/talder/xyOps-MSSQL-Information/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![dbatools](https://img.shields.io/badge/dbatools-2.0+-green.svg)](https://dbatools.io)

Collect comprehensive information from Microsoft SQL Server instances using PowerShell and [dbatools](https://dbatools.io). This plugin gathers server details, Availability Group configurations, database information, and user accounts in a single execution.

## Disclaimer

**USE AT YOUR OWN RISK.** This software is provided "as is", without warranty of any kind, express or implied. The author and contributors are not responsible for any damages, data loss, system downtime, or other issues that may arise from the use of this software. Always test in non-production environments before running against production systems. By using this plugin, you acknowledge that you have read, understood, and accepted this disclaimer.

## Features

- Server information (version, edition, clustering status, patch level)
- Availability Groups details (if configured)
- Database inventory with separate data/log sizes, status, and backup info
- Database user accounts with role memberships
- Configurable encryption and certificate validation
- Multiple export formats: JSON, CSV (separate files per section), and Markdown
- Optional file export alongside job output
- Exclude specific databases from collection
- Auto-installs dbatools PowerShell module if missing
- Automatic primary replica failover for AG databases
- SQL Server patch status with latest CU download links

## Requirements

### CLI Requirements

- **PowerShell Core (pwsh)** - Version 7.0 or later recommended
  - On macOS: `brew install powershell`
  - On Linux: [Install instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
  - On Windows: Comes pre-installed or [download](https://aka.ms/powershell-release)

### Module Requirements

- **dbatools** - Automatically installed by the plugin if not present
  - The plugin will attempt to install dbatools using `Install-Module -Name dbatools -Scope CurrentUser`
  - Requires internet connection for first-time installation

### Secret Vault Configuration

**IMPORTANT**: This plugin requires SQL Server credentials to be stored in an xyOps secret vault for secure authentication.

#### Setting Up the Secret Vault

1. **Create a Secret Vault** in xyOps (e.g., named `MSSQL-INFO-PLUGIN`)
2. **Add the following keys** to the vault:
   - `MSSQLINFO_USERNAME` - Your SQL Server username
   - `MSSQLINFO_PASSWORD` - Your SQL Server password

3. **Attach the vault** to the plugin when configuring it

The plugin will automatically read credentials from these environment variables at runtime.

**Note**: Username and password are NOT passed as plugin parameters. All authentication is handled securely through environment variables populated from the secret vault.

For detailed instructions on creating and managing secret vaults, see the [xyOps Secrets Documentation](https://github.com/pixlcore/xyops/blob/main/docs/secrets.md).

### SQL Server Permissions

**IMPORTANT**: The SQL Server user account must have sufficient permissions to query:
- Server-level properties (`VIEW SERVER STATE`)
- Availability Group information (`VIEW ANY DEFINITION`)
- Database metadata (`VIEW DATABASE STATE` on all databases)
- User information in databases

Recommended: Use a SQL Server login with `sysadmin` role or a user with the following permissions:
- `VIEW SERVER STATE`
- `VIEW ANY DEFINITION`
- Member of `db_datareader` role in all target databases

### Availability Groups - Important Note

**CRITICAL for AG Environments**: When running this plugin on an Availability Group secondary replica, the plugin will automatically connect to the primary replica to gather database information for databases that are not readable on the secondary.

**Requirements**:
- **Same credentials must work on both primary and secondary replicas**
- The username and password provided must have the same permissions on all AG replicas
- Network connectivity must be allowed between the xyOps server and all AG replicas
- If credentials differ between replicas, the plugin will not be able to collect complete information for AG databases

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| MSSQL server | text | Yes | - | SQL Server address (hostname or IP) |
| Databases to exclude | text | No | - | Comma-separated list of database names to exclude (e.g., "DB1,DB2,DB3") |
| Use encryption | checkbox | No | false | Enable encrypted connection |
| Trust certificate | checkbox | No | false | Trust server certificate (bypass validation) |
| Export format | dropdown | No | JSON | Export format: JSON, CSV, or MD (Markdown) |
| Export to file | checkbox | No | false | Export data to file(s) in addition to job output |
| Enable debug mode | checkbox | No | false | Enable debug output |

**Authentication**: Credentials (`MSSQLINFO_USERNAME` and `MSSQLINFO_PASSWORD`) must be configured in a secret vault attached to this plugin. See [Secret Vault Configuration](#secret-vault-configuration) above.

**Note**: System databases (master, model, msdb, tempdb) are automatically excluded from collection.

## Output Formats

The plugin supports three export formats, selectable via the **Export format** parameter:

### Markdown (MD) - Default Display Format

When **Export format** is set to **MD** (default), the plugin generates a **Markdown-formatted report** with professional tables in the xyOps job output:

#### 1. Server Information

| Field | Description | Example |
|-------|-------------|--------|
| ServerName | SQL Server hostname | SQL01.company.com |
| SQLVersion | Friendly version name | SQL Server 2022 |
| Version | Full version string | 16.0.1000.6 |
| BuildNumber | Build number only | 1000.6 |
| Edition | SQL Server edition | Enterprise Edition (64-bit) |
| ProductLevel | RTM or Service Pack | RTM |
| ProductUpdateLevel | Current patch installed | CU15 or RTM (Not Patched) |
| UpdateStatus | Patch status indicator | ✅ Up-to-date or ⚠️ 3 CU(s) behind |
| LatestCU | Download link to latest CU | Clickable link to Microsoft |
| IsClustered | Windows clustering status | Yes or No |
| IsHadrEnabled | Availability Group status | Yes or No |

#### 2. Availability Groups (if configured)

| Field | Description | Example |
|-------|-------------|--------|
| Name | Availability Group name | AG-PROD |
| PrimaryReplica | Current primary server | SQL01 |
| LocalReplicaRole | Role on this server | Primary or Secondary |
| AutomatedBackupPreference | Backup preference setting | Secondary |
| ListenerDNS | Listener DNS name | AG-PROD-LISTENER |
| ListenerPort | Listener TCP port | 1433 |
| ListenerIP | Listener IP address | 10.0.1.100 |
| Replicas | All replica servers | SQL01, SQL02 |

**Note**: This section only appears if the SQL Server has Availability Groups enabled.

### 3. Databases
- Database Name (includes "via primary" note if queried from AG primary)
- Data Size (GB) - Size of .mdf/.ndf files
- Log Size (GB) - Size of .ldf files
- Total Size (GB) - Combined data + log
- Status (Online, Offline, Restoring, etc.)
- Recovery Model (Full, Simple, BulkLogged)
- Owner
- Active Connections
- In Availability Group (Yes/No, with AG name)
- Last Full Backup (date/time or "Never")

**AG Database Handling**: For databases in Availability Groups that are not readable on the current replica, the plugin automatically connects to the primary replica to gather information.

### 4. Database Users
- Database Name
- User Name
- Login Type
- Roles/Permissions (e.g., "db_owner, db_datareader")
- Has DB Access (Yes/No)
- Create Date

This table lists all non-system users across all databases.

## JSON Data Output

In addition to tables, the plugin outputs structured JSON data that can be used in workflows or stored in buckets:

```json
{
  "server": {
    "ServerName": "SQL01",
    "Version": "15.0.4365.2",
    "Edition": "Enterprise Edition",
    "ProductLevel": "RTM",
    "IsClustered": false,
    "IsHadrEnabled": true
  },
  "availabilityGroups": [
    {
      "Name": "AG-PROD",
      "PrimaryReplica": "SQL01",
      "LocalReplicaRole": "Primary",
      "AutomatedBackupPreference": "Secondary",
      "ListenerDNS": "AG-PROD-LISTENER",
      "ListenerPort": 1433,
      "ListenerIP": "10.0.1.100",
      "Replicas": "SQL01, SQL02"
    }
  ],
  "databases": [
    {
      "DatabaseName": "ProductionDB",
      "SizeGB": 125.50,
      "Status": "Normal",
      "RecoveryModel": "Full",
      "Owner": "sa",
      "ActiveConnections": 15,
      "InAvailabilityGroup": "Yes (AG-PROD)",
      "LastFullBackup": "2026-01-31 08:30:00",
      "CompatibilityLevel": "Version150"
    }
  ],
  "databaseUsers": [
    {
      "DatabaseName": "ProductionDB",
      "UserName": "app_user",
      "LoginType": "SqlLogin",
      "CreateDate": "2025-12-01 10:00:00",
      "HasDBAccess": true
    }
  ]
}
```

This JSON data is accessible via the `data` bucket or can be passed to subsequent workflow steps.

## Usage Examples

**Note**: All examples require a secret vault with `MSSQLINFO_USERNAME` and `MSSQLINFO_PASSWORD` to be attached to the plugin.

### Basic Server Inventory (Markdown Display)

Collect information from a standalone SQL Server with Markdown tables:

**Parameters:**
- MSSQL server: `sqlserver.company.com`
- Export format: `MD` (default)

### JSON Export for Workflows

Collect data in JSON format for workflow processing:

**Parameters:**
- MSSQL server: `sqlserver.company.com`
- Export format: `JSON`
- Use encryption: ✓ (checked)

### CSV Export to Files

Export data to separate CSV files for Excel analysis:

**Parameters:**
- MSSQL server: `ag-listener.company.com`
- Export format: `CSV`
- Export to file: ✓ (checked)

**Result**: Creates 4 CSV files (server_info, availability_groups, databases, database_users) with timestamp.

### Exclude Specific Databases

Collect information but skip certain databases:

**Parameters:**
- MSSQL server: `sqlserver.company.com`
- Exclude databases: `TestDB,StagingDB,TempData`
- Export format: `MD`

## Connection Security

### Encryption

Enable the **Use encryption** checkbox to force encrypted connections. This is recommended when connecting over untrusted networks.

**Note**: Your SQL Server must be configured to support encryption, or you must enable **Trust certificate** to bypass certificate validation.

### Certificate Validation

The **Trust certificate** checkbox allows you to bypass SSL/TLS certificate validation. Use this when:

- Connecting to servers with self-signed certificates
- Working in development/testing environments
- Dealing with certificate name mismatches

**Security Warning**: Only use **Trust certificate** in trusted environments. In production, properly configure SSL certificates on your SQL Server.

## Debug Mode

Enable the **Enable debug mode** checkbox to see detailed execution information including:

- Input parameter values
- Connection settings
- Progress updates for each collection step
- Warning messages for partial failures

Debug output appears in the job logs (stderr).

## Error Codes

| Code | Description |
|------|-------------|
| 1 | Failed to parse input JSON |
| 2 | Missing required parameters |
| 3 | Failed to install dbatools module |
| 5 | General error during execution |

## Use Cases

### 1. Server Inventory Automation
Run this plugin on a schedule to maintain an up-to-date inventory of all SQL Servers, storing results in a bucket for reporting.

### 2. Availability Group Health Checks
Monitor AG configuration and replica status across your environment.

### 3. Database Growth Tracking
Collect database sizes regularly to track growth trends and plan capacity.

### 4. User Access Auditing
List all database users across your SQL Server estate for security audits.

### 5. Backup Compliance
Verify that all databases have recent backups by checking the LastFullBackup column.

## Workflow Integration

The JSON output can be used in xyOps workflows:

1. **Trigger**: Schedule (daily/weekly)
2. **Step 1**: Run MSSQL Information plugin → outputs data to bucket
3. **Step 2**: Parse JSON data in subsequent workflow steps
4. **Step 3**: Send alerts if:
   - Databases haven't been backed up in 24 hours
   - Database sizes exceed thresholds
   - AG replicas are not synchronizing

## Troubleshooting

### Permission Denied

**Error**: "The SELECT permission was denied on the object..."

**Solution**: Ensure the SQL Server user has appropriate permissions. Grant `VIEW SERVER STATE` and `VIEW ANY DEFINITION` permissions:

```sql
USE master;
GO
GRANT VIEW SERVER STATE TO [your_user];
GRANT VIEW ANY DEFINITION TO [your_user];
GO
```

### Cannot Collect AG Information

**Error/Warning**: "Could not collect AG information..."

**Solution**: This is normal for standalone SQL Servers without Availability Groups. The AG table will simply not appear in the output.

### dbatools Installation Fails

If automatic installation fails, manually install dbatools:

```powershell
Install-Module -Name dbatools -Force -AllowClobber -Scope CurrentUser
```

### Connection Fails with Certificate Error

Enable the **Trust certificate** checkbox to bypass certificate validation, or properly configure SSL on your SQL Server.

## Performance Considerations

- Collection time scales with the number of databases
- For servers with 100+ databases, expect 30-60 seconds execution time
- User collection can be slow on databases with many users
- Consider using **Exclude databases** to skip large or irrelevant databases

## Data Collection

This plugin does not collect any user data or metrics beyond what is sent to the xyOps job output. All data collection and processing happens locally within the xyOps environment.

## Comparison with MSSQL Query Plugin

| Feature | MSSQL Information | MSSQL Query |
|---------|-------------------|-------------|
| Purpose | Collect metadata | Execute custom queries |
| Output | Predefined tables | User-defined results |
| AG Support | ✓ Built-in | Manual queries needed |
| Backup Info | ✓ Built-in | Manual queries needed |
| Custom Queries | ✗ | ✓ |
| Use Case | Inventory/Monitoring | Data extraction |

## Links

- [dbatools Documentation](https://dbatools.io)
- [dbatools GitHub](https://github.com/dataplat/dbatools)
- [PowerShell Installation](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- [SQL Server Availability Groups](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)

## License

MIT License - See [LICENSE.md](LICENSE.md) for details.

## Author

Tim Alderweireldt

## Version

1.0.1
