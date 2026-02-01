# (c)2026 Tim Alderweireldt - xyOps MSSQL Information Plugin - PowerShell Version
# Collects comprehensive information from Microsoft SQL Server instances using dbatools

function Write-Output-JSON {
    param($Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 100
    Write-Output $json
    [Console]::Out.Flush()
}

function Send-Progress {
    param([double]$Value)
    Write-Output-JSON @{ xy = 1; progress = $Value }
}

function Send-Table {
    param($Title, $Data, $Caption = "")
    
    if ($null -eq $Data -or $Data.Count -eq 0) {
        return
    }
    
    # Convert data to array of PSCustomObjects if it's hashtables
    $tableData = $Data | ForEach-Object { 
        if ($_ -is [hashtable]) {
            [PSCustomObject]$_
        } else {
            $_
        }
    }
    
    $headers = $tableData[0].PSObject.Properties.Name
    $rows = @()
    
    foreach ($record in $tableData) {
        $row = @()
        foreach ($header in $headers) {
            $value = $record.$header
            if ($null -eq $value) {
                $row += ""
            }
            elseif ($value -is [array] -or $value -is [hashtable]) {
                $row += ($value | ConvertTo-Json -Compress)
            }
            else {
                $row += $value.ToString()
            }
        }
        $rows += ,@($row)
    }
    
    Write-Output-JSON @{
        xy = 1
        table = @{
            title = $Title
            header = $headers
            rows = $rows
            caption = if ($Caption) { $Caption } else { "$($tableData.Count) row(s)" }
        }
    }
}

function Send-Success {
    param([string]$Description = "Information collected successfully")
    Write-Output-JSON @{ xy = 1; code = 0; description = $Description }
}

function Send-Error {
    param([int]$Code, [string]$Description)
    Write-Output-JSON @{ xy = 1; code = $Code; description = $Description }
}

# Read input from STDIN
$inputJson = [Console]::In.ReadToEnd()

try {
    $jobData = $inputJson | ConvertFrom-Json -AsHashtable
}
catch {
    Send-Error -Code 1 -Description "Failed to parse input JSON: $($_.Exception.Message)"
    exit 1
}

# Extract parameters
$params = $jobData.params

# Helper function to get parameter value case-insensitively
function Get-ParamValue {
    param($ParamsObject, [string]$ParamName)
    if ($ParamsObject -is [hashtable]) {
        foreach ($key in $ParamsObject.Keys) {
            if ($key -ieq $ParamName) {
                return $ParamsObject[$key]
            }
        }
        return $null
    } else {
        $prop = $ParamsObject.PSObject.Properties | Where-Object { $_.Name -ieq $ParamName } | Select-Object -First 1
        if ($prop) { return $prop.Value }
        return $null
    }
}

# Check if debug mode is enabled
$debugRaw = Get-ParamValue -ParamsObject $params -ParamName 'debug'
$debug = if ($debugRaw -eq $true -or $debugRaw -eq "true" -or $debugRaw -eq "True") { $true } else { $false }

# If debug is enabled, output the incoming JSON
if ($debug) {
    Write-Host "=== DEBUG: Incoming JSON ==="
    $debugData = @{}
    if ($jobData -is [hashtable]) {
        foreach ($key in $jobData.Keys) {
            if ($key -ne 'script') {
                $debugData[$key] = $jobData[$key]
            }
        }
    } else {
        foreach ($prop in $jobData.PSObject.Properties) {
            if ($prop.Name -ne 'script') {
                $debugData[$prop.Name] = $prop.Value
            }
        }
    }
    $formattedJson = $debugData | ConvertTo-Json -Depth 10
    Write-Host $formattedJson
    Write-Host "=== END DEBUG ==="
}

$server = Get-ParamValue -ParamsObject $params -ParamName 'server'
$username = $env:MSSQLINFO_USERNAME
$password = $env:MSSQLINFO_PASSWORD
$excludeDatabasesRaw = Get-ParamValue -ParamsObject $params -ParamName 'excludedatabases'
$excludeDatabases = if ([string]::IsNullOrWhiteSpace($excludeDatabasesRaw)) { @() } else { $excludeDatabasesRaw -split ',' | ForEach-Object { $_.Trim() } }
$exportFormatRaw = Get-ParamValue -ParamsObject $params -ParamName 'exportformat'
$exportFormat = if ([string]::IsNullOrWhiteSpace($exportFormatRaw)) { "JSON" } else { $exportFormatRaw.ToUpper() }
$exportToFileRaw = Get-ParamValue -ParamsObject $params -ParamName 'exporttofile'
$exportToFile = if ($exportToFileRaw -eq $true -or $exportToFileRaw -eq "true" -or $exportToFileRaw -eq "True") { $true } else { $false }

# Validate required parameters
$missing = @()

# Check server parameter
if ([string]::IsNullOrWhiteSpace($server)) {
    $missing += 'server'
}

# Check username from environment variable
if ([string]::IsNullOrWhiteSpace($username)) {
    $missing += 'MSSQLINFO_USERNAME (environment variable)'
}

# Check password from environment variable
if ([string]::IsNullOrWhiteSpace($password)) {
    $missing += 'MSSQLINFO_PASSWORD (environment variable)'
}

if ($missing.Count -gt 0) {
    Send-Error -Code 2 -Description "Missing required parameters: $($missing -join ', '). Credentials must be provided via secret vault environment variables."
    exit 1
}

try {
    # Check if dbatools module is installed
    Send-Progress -Value 0.1
    
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        try {
            Write-Host "dbatools module not found, attempting to install..."
            Install-Module -Name dbatools -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
            Write-Host "dbatools module installed successfully"
        }
        catch {
            Send-Error -Code 3 -Description "Failed to install required dbatools module. Please install it manually by running: Install-Module -Name dbatools -Force (Install error: $($_.Exception.Message))"
            exit 1
        }
    }
    
    # Import dbatools module
    Send-Progress -Value 0.2
    Import-Module dbatools -ErrorAction Stop
    
    # Build connection parameters
    Send-Progress -Value 0.3
    
    # Extract and convert encryption parameters
    $useencryptionRaw = Get-ParamValue -ParamsObject $params -ParamName 'useencryption'
    $trustcertRaw = Get-ParamValue -ParamsObject $params -ParamName 'trustcert'
    
    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
    
    # Build Connect-DbaInstance parameters with encryption settings
    $connectParams = @{
        SqlInstance = $server
        SqlCredential = $credential
    }
    
    # Add encryption parameter if enabled
    if ($useencryptionRaw -eq $true -or $useencryptionRaw -eq "true" -or $useencryptionRaw -eq "True") {
        $connectParams['EncryptConnection'] = $true
        Write-Host "Encryption enabled"
    }
    
    # Add TrustServerCertificate parameter if enabled
    if ($trustcertRaw -eq $true -or $trustcertRaw -eq "true" -or $trustcertRaw -eq "True") {
        $connectParams['TrustServerCertificate'] = $true
        Write-Host "TrustServerCertificate enabled"
    }
    
    # Create connection using Connect-DbaInstance
    Write-Host "Connecting to $server with encryption=$useencryptionRaw, trustcert=$trustcertRaw"
    $serverConnection = Connect-DbaInstance @connectParams
    
    Send-Progress -Value 0.4
    
    # Collect server information
    Write-Host "Collecting server information..."
    
    # Determine patch level (show RTM if not patched)
    $patchLevel = if ([string]::IsNullOrWhiteSpace($serverConnection.ProductUpdateLevel)) { "RTM (Not Patched)" } else { $serverConnection.ProductUpdateLevel }
    
    # Extract current CU number if available
    $currentCuNumber = $null
    if ($patchLevel -match 'CU\s?(\d+)') {
        $currentCuNumber = [int]$matches[1]
        Write-Host "Current CU installed: CU$currentCuNumber"
    } elseif ($patchLevel -ne "RTM (Not Patched)") {
        Write-Host "Current patch level: $patchLevel"
    } else {
        Write-Host "No CU installed (RTM version)"
    }
    
    # Get major version from VersionString (e.g., "16.0.1000.6" -> "2022")
    $versionMajor = $serverConnection.VersionMajor
    $sqlVersionName = switch ($versionMajor) {
        16 { "SQL Server 2022" }
        15 { "SQL Server 2019" }
        14 { "SQL Server 2017" }
        13 { "SQL Server 2016" }
        12 { "SQL Server 2014" }
        11 { "SQL Server 2012" }
        10 { "SQL Server 2008/2008 R2" }
        default { "SQL Server (Unknown Version)" }
    }
    
    # Get latest CU download link based on version
    Write-Host "Getting latest CU info for $sqlVersionName..."
    $latestCU = "N/A"
    $downloadLink = ""
    $cuNumber = ""
    
    # Try to fetch latest CU number from Microsoft's update history pages
    try {
        $buildReferenceUrl = switch ($versionMajor) {
            16 { "https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions" }
            15 { "https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions" }
            14 { "https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/build-versions" }
            13 { "https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2016/build-versions" }
            default { $null }
        }
        
        if ($buildReferenceUrl) {
            Write-Host "Fetching latest CU from: $buildReferenceUrl"
            $response = Invoke-WebRequest -Uri $buildReferenceUrl -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            
            # Look for CU pattern in the content (e.g., "CU15", "CU 15", "Cumulative Update 15")
            if ($response.Content -match 'CU\s?(\d+)|Cumulative Update\s+(\d+)') {
                # Find all CU numbers and get the highest one
                $cuMatches = [regex]::Matches($response.Content, 'CU\s?(\d+)|Cumulative Update\s+(\d+)')
                $cuNumbers = @()
                foreach ($match in $cuMatches) {
                    if ($match.Groups[1].Value) {
                        $cuNumbers += [int]$match.Groups[1].Value
                    } elseif ($match.Groups[2].Value) {
                        $cuNumbers += [int]$match.Groups[2].Value
                    }
                }
                if ($cuNumbers.Count -gt 0) {
                    $latestCuNum = ($cuNumbers | Measure-Object -Maximum).Maximum
                    $cuNumber = "CU$latestCuNum"
                    Write-Host "Latest CU detected: $cuNumber"
                    
                    # Compare with current CU if available
                    if ($null -ne $currentCuNumber) {
                        if ($currentCuNumber -eq $latestCuNum) {
                            Write-Host "Server is up-to-date (CU$currentCuNumber = $cuNumber)"
                        } elseif ($currentCuNumber -lt $latestCuNum) {
                            $cusBehind = $latestCuNum - $currentCuNumber
                            Write-Host "Server is $cusBehind CU(s) behind (Current: CU$currentCuNumber, Latest: $cuNumber)"
                        } else {
                            Write-Host "Server has newer version than detected (Current: CU$currentCuNumber, Latest: $cuNumber)"
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Host "Could not fetch latest CU number: $($_.Exception.Message)"
    }
    
    # Determine update status
    $updateStatus = "Unknown"
    if ($cuNumber -match 'CU(\d+)') {
        $latestCuNum = [int]$matches[1]
        if ($null -ne $currentCuNumber) {
            if ($currentCuNumber -eq $latestCuNum) {
                $updateStatus = "✅ Up-to-date"
            } elseif ($currentCuNumber -lt $latestCuNum) {
                $cusBehind = $latestCuNum - $currentCuNumber
                $updateStatus = "⚠️ $cusBehind CU(s) behind"
            } else {
                $updateStatus = "✅ Newer than latest detected"
            }
        } elseif ($patchLevel -eq "RTM (Not Patched)") {
            $updateStatus = "⚠️ Not patched (RTM)"
        }
    }
    
    # Build the download link text with CU number if found
    $latestCU = switch ($versionMajor) {
        16 { 
            $downloadLink = "https://www.microsoft.com/en-us/download/details.aspx?id=105013"
            if ($cuNumber) {
                "[SQL Server 2022 $cuNumber (Download)]($downloadLink)"
            } else {
                "[Latest CU for SQL Server 2022 (Download)]($downloadLink)"
            }
        }
        15 { 
            $downloadLink = "https://www.microsoft.com/en-us/download/details.aspx?id=100809"
            if ($cuNumber) {
                "[SQL Server 2019 $cuNumber (Download)]($downloadLink)"
            } else {
                "[Latest CU for SQL Server 2019 (Download)]($downloadLink)"
            }
        }
        14 { 
            $downloadLink = "https://www.microsoft.com/en-us/download/details.aspx?id=56128"
            if ($cuNumber) {
                "[SQL Server 2017 $cuNumber (Download)]($downloadLink)"
            } else {
                "[Latest CU for SQL Server 2017 (Download)]($downloadLink)"
            }
        }
        13 { 
            $downloadLink = "https://www.microsoft.com/en-us/download/details.aspx?id=53338"
            if ($cuNumber) {
                "[SQL Server 2016 $cuNumber (Download)]($downloadLink)"
            } else {
                "[Latest Service Pack for SQL Server 2016 (Download)]($downloadLink)"
            }
        }
        12 { 
            "End of Support - No longer receiving updates"
        }
        default { 
            "Version out of mainstream support"
        }
    }
    
    $serverInfo = @{
        ServerName = $serverConnection.Name
        SQLVersion = $sqlVersionName
        Version = $serverConnection.VersionString
        BuildNumber = $serverConnection.BuildNumber
        Edition = $serverConnection.Edition
        ProductLevel = $serverConnection.ProductLevel
        ProductUpdateLevel = $patchLevel
        UpdateStatus = $updateStatus
        LatestCU = $latestCU
        IsClustered = if ($serverConnection.IsClustered) { "Yes" } else { "No" }
        IsHadrEnabled = if ($serverConnection.IsHadrEnabled) { "Yes" } else { "No" }
    }
    
    Send-Progress -Value 0.5
    
    # Initialize data collections
    $allData = @{
        server = $serverInfo
        availabilityGroups = @()
        databases = @()
        databaseUsers = @()
    }
    
    # Collect Availability Groups information if enabled
    if ($serverConnection.IsHadrEnabled) {
        Write-Host "Collecting Availability Groups information..."
        try {
            $ags = Get-DbaAvailabilityGroup -SqlInstance $serverConnection
            
            foreach ($ag in $ags) {
                $agInfo = @{
                    Name = $ag.Name
                    PrimaryReplica = $ag.PrimaryReplica
                    LocalReplicaRole = $ag.LocalReplicaRole.ToString()
                    AutomatedBackupPreference = $ag.AutomatedBackupPreference.ToString()
                }
                
                # Get listener information
                $listener = $ag.AvailabilityGroupListeners | Select-Object -First 1
                if ($listener) {
                    $agInfo['ListenerDNS'] = $listener.Name
                    $agInfo['ListenerPort'] = $listener.PortNumber.ToString()
                    $agInfo['ListenerIP'] = ($listener.AvailabilityGroupListenerIPAddresses | Select-Object -ExpandProperty IPAddress) -join ', '
                } else {
                    $agInfo['ListenerDNS'] = "N/A"
                    $agInfo['ListenerPort'] = "N/A"
                    $agInfo['ListenerIP'] = "N/A"
                }
                
                # Get replicas
                $replicas = Get-DbaAgReplica -SqlInstance $serverConnection -AvailabilityGroup $ag.Name
                $agInfo['Replicas'] = ($replicas.Name -join ', ')
                
                $allData.availabilityGroups += $agInfo
            }
        }
        catch {
            Write-Host "Warning: Could not collect AG information: $($_.Exception.Message)"
        }
    }
    
    Send-Progress -Value 0.6
    
    # Collect database information
    Write-Host "Collecting database information..."
    $systemDatabases = @('master', 'model', 'msdb', 'tempdb')
    $databases = Get-DbaDatabase -SqlInstance $serverConnection | Where-Object { 
        $systemDatabases -notcontains $_.Name -and $excludeDatabases -notcontains $_.Name 
    }
    
    Send-Progress -Value 0.7
    
    foreach ($db in $databases) {
        Write-Host "Processing database: $($db.Name)"
        
        # Determine which server to query for this database
        $queryConnection = $serverConnection
        $connectionNote = ""
        
        # Check if database is in AG and not accessible on this replica
        if ($db.AvailabilityGroupName) {
            Write-Host "Database $($db.Name) is in AG: $($db.AvailabilityGroupName)"
            
            # Try to find the primary replica for this AG
            try {
                $ag = Get-DbaAvailabilityGroup -SqlInstance $serverConnection -AvailabilityGroup $db.AvailabilityGroupName -ErrorAction Stop
                $primaryReplica = $ag.PrimaryReplica
                
                # If we're not on the primary, try to connect to it
                if ($primaryReplica -and $primaryReplica -ne $serverConnection.Name) {
                    Write-Host "Database is on AG, primary replica is $primaryReplica (current: $($serverConnection.Name))"
                    
                    try {
                        # Try to connect to primary replica with same credentials
                        $primaryConnectParams = @{
                            SqlInstance = $primaryReplica
                            SqlCredential = $credential
                        }
                        
                        if ($useencryptionRaw -eq $true -or $useencryptionRaw -eq "true" -or $useencryptionRaw -eq "True") {
                            $primaryConnectParams['EncryptConnection'] = $true
                        }
                        if ($trustcertRaw -eq $true -or $trustcertRaw -eq "true" -or $trustcertRaw -eq "True") {
                            $primaryConnectParams['TrustServerCertificate'] = $true
                        }
                        
                        $queryConnection = Connect-DbaInstance @primaryConnectParams -ErrorAction Stop
                        $connectionNote = " (via primary: $primaryReplica)"
                        Write-Host "Successfully connected to primary replica: $primaryReplica"
                    }
                    catch {
                        Write-Host "Warning: Could not connect to primary replica $primaryReplica : $($_.Exception.Message)"
                        Write-Host "Will attempt to query on current server anyway"
                    }
                }
            }
            catch {
                Write-Host "Warning: Could not determine AG primary for $($db.Name): $($_.Exception.Message)"
            }
        }
        
        # Get last backup information
        $lastFullBackup = Get-DbaDbBackupHistory -SqlInstance $queryConnection -Database $db.Name -LastFull -WarningAction SilentlyContinue | Select-Object -First 1
        
        # Get database size - separate data and log files using dbatools
        $dataSize = 0
        $logSize = 0
        
        try {
            # Get file information using dbatools to avoid SMO enumeration issues
            $dbFiles = Get-DbaDbFile -SqlInstance $queryConnection -Database $db.Name -ErrorAction Stop
            
            foreach ($file in $dbFiles) {
                if ($file.TypeDescription -eq 'LOG') {
                    $logSize += $file.Size.Megabyte
                } else {
                    $dataSize += $file.Size.Megabyte
                }
            }
            
            $dataSizeGB = [math]::Round($dataSize / 1024, 2)
            $logSizeGB = [math]::Round($logSize / 1024, 2)
            $totalSizeGB = [math]::Round(($dataSize + $logSize) / 1024, 2)
        }
        catch {
            Write-Host "Warning: Could not get file sizes for $($db.Name), using database total size: $($_.Exception.Message)"
            # Fallback to total database size if file enumeration fails
            $totalSizeGB = [math]::Round($db.Size / 1KB, 2)
            $dataSizeGB = $totalSizeGB
            $logSizeGB = 0
        }
        
        # Check if database is in AG
        $inAG = if ($db.AvailabilityGroupName) { "Yes ($($db.AvailabilityGroupName))" } else { "No" }
        
        # Get active connections
        $connections = (Get-DbaProcess -SqlInstance $queryConnection -Database $db.Name).Count
        
        $dbInfo = @{
            DatabaseName = $db.Name + $connectionNote
            DataSizeGB = $dataSizeGB
            LogSizeGB = $logSizeGB
            TotalSizeGB = $totalSizeGB
            Status = $db.Status.ToString()
            RecoveryModel = $db.RecoveryModel.ToString()
            Owner = $db.Owner
            ActiveConnections = $connections
            InAvailabilityGroup = $inAG
            LastFullBackup = if ($lastFullBackup) { $lastFullBackup.End.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
            CompatibilityLevel = $db.CompatibilityLevel.ToString()
        }
        
        $allData.databases += $dbInfo
        
        # Collect database users with permissions
        try {
            $users = Get-DbaDbUser -SqlInstance $queryConnection -Database $db.Name | Where-Object { 
                -not $_.IsSystemObject 
            }
            
            foreach ($user in $users) {
                # Get user roles/permissions using dbatools
                $roles = @()
                try {
                    # Use Get-DbaDbRoleMember to get role memberships
                    $roleMemberships = Get-DbaDbRoleMember -SqlInstance $queryConnection -Database $db.Name -IncludeSystemUser -ErrorAction Stop | Where-Object { $_.UserName -eq $user.Name }
                    
                    if ($roleMemberships) {
                        $roles = @($roleMemberships | Select-Object -ExpandProperty Role -Unique)
                    }
                } catch {
                    Write-Host "Could not get roles for user $($user.Name) in $($db.Name): $($_.Exception.Message)"
                }
                
                $rolesList = if ($roles.Count -gt 0) { $roles -join ', ' } else { "None" }
                
                $userInfo = @{
                    DatabaseName = $db.Name
                    UserName = $user.Name
                    LoginType = $user.LoginType.ToString()
                    Roles = $rolesList
                    CreateDate = $user.CreateDate.ToString("yyyy-MM-dd HH:mm:ss")
                    HasDBAccess = if ($user.HasDBAccess) { "Yes" } else { "No" }
                }
                
                $allData.databaseUsers += $userInfo
            }
        }
        catch {
            Write-Host "Warning: Could not collect users for database $($db.Name): $($_.Exception.Message)"
        }
    }
    
    Send-Progress -Value 0.9
    
    # Build Markdown output with sections
    Write-Host "Building Markdown output..."
    $markdownContent = ""
    
    # Server Information Section
    $markdownContent += "## Server Information`n`n"
    $markdownContent += "| Property | Value |`n"
    $markdownContent += "|----------|-------|`n"
    $markdownContent += "| **Server Name** | $($serverInfo.ServerName) |`n"
    $markdownContent += "| **SQL Version** | $($serverInfo.SQLVersion) |`n"
    $markdownContent += "| **Version String** | $($serverInfo.Version) |`n"
    $markdownContent += "| **Build Number** | $($serverInfo.BuildNumber) |`n"
    $markdownContent += "| **Edition** | $($serverInfo.Edition) |`n"
    $markdownContent += "| **Product Level** | $($serverInfo.ProductLevel) |`n"
    $markdownContent += "| **Current Patch** | $($serverInfo.ProductUpdateLevel) |`n"
    $markdownContent += "| **Update Status** | $($serverInfo.UpdateStatus) |`n"
    $markdownContent += "| **Latest CU Download** | $($serverInfo.LatestCU) |`n"
    $markdownContent += "| **Is Clustered** | $($serverInfo.IsClustered) |`n"
    $markdownContent += "| **HADR Enabled** | $($serverInfo.IsHadrEnabled) |`n"
    $markdownContent += "`n"
    
    # Availability Groups Section
    if ($allData.availabilityGroups.Count -gt 0) {
        $markdownContent += "## Availability Groups ($($allData.availabilityGroups.Count))`n`n"
        $markdownContent += "| AG Name | Primary Replica | Role | Listener | Replicas |`n"
        $markdownContent += "|---------|----------------|------|----------|----------|`n"
        
        foreach ($ag in $allData.availabilityGroups) {
            $listener = "$($ag.ListenerDNS):$($ag.ListenerPort) (IP: $($ag.ListenerIP))"
            $markdownContent += "| **$($ag.Name)** | $($ag.PrimaryReplica) | $($ag.LocalReplicaRole) | $listener | $($ag.Replicas) |`n"
        }
        
        $markdownContent += "`n"
    }
    
    # Databases Section
    if ($allData.databases.Count -gt 0) {
        $markdownContent += "## Databases ($($allData.databases.Count))`n`n"
        $markdownContent += "| Database | Data (GB) | Log (GB) | Total (GB) | Status | Recovery Model | Owner | Connections | Last Backup | In AG |`n"
        $markdownContent += "|----------|-----------|----------|------------|--------|----------------|-------|-------------|-------------|-------|`n"
        
        foreach ($db in $allData.databases) {
            $markdownContent += "| **$($db.DatabaseName)** | $($db.DataSizeGB) | $($db.LogSizeGB) | $($db.TotalSizeGB) | $($db.Status) | $($db.RecoveryModel) | $($db.Owner) | $($db.ActiveConnections) | $($db.LastFullBackup) | $($db.InAvailabilityGroup) |`n"
        }
        
        $markdownContent += "`n"
    }
    
    # Database Users Section
    if ($allData.databaseUsers.Count -gt 0) {
        $markdownContent += "## Database Users ($($allData.databaseUsers.Count))`n`n"
        $markdownContent += "| Database | User Name | Login Type | Roles/Permissions | Has DB Access | Created |`n"
        $markdownContent += "|----------|-----------|------------|-------------------|---------------|---------|`n"
        
        foreach ($user in $allData.databaseUsers) {
            $markdownContent += "| $($user.DatabaseName) | **$($user.UserName)** | $($user.LoginType) | $($user.Roles) | $($user.HasDBAccess) | $($user.CreateDate) |`n"
        }
        
        $markdownContent += "`n"
    }
    
    # Always output the Markdown for display
    $caption = "Server: $($serverInfo.ServerName) | $($allData.databases.Count) Database(s) | $($allData.databaseUsers.Count) User(s) | $($allData.availabilityGroups.Count) Availability Group(s)"
    Write-Output-JSON @{
        xy = 1
        markdown = @{
            title = "SQL Server Information Report"
            content = $markdownContent
            caption = $caption
        }
    }
    
    # Output data in requested format
    Write-Host "Outputting data in $exportFormat format..."
    
    switch ($exportFormat) {
        "JSON" {
            if ($exportToFile) {
                # Generate filename with timestamp
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $filename = "sqlserver_info_$($serverInfo.ServerName)_$timestamp.json"
                
                # Write JSON to file
                $allData | ConvertTo-Json -Depth 100 | Out-File -FilePath $filename -Encoding UTF8
                Write-Host "JSON file created: $filename"
                
                # Output JSON data AND file reference
                $jsonData = @{
                    xy = 1
                    data = $allData
                    files = @(
                        @{
                            path = $filename
                            name = $filename
                        }
                    )
                }
                Write-Output-JSON $jsonData
            } else {
                # Output JSON data only (no file)
                $jsonData = @{
                    xy = 1
                    data = $allData
                }
                Write-Output-JSON $jsonData
            }
        }
        "CSV" {
            # Build separate CSV files for each section
            Write-Host "Building CSV output..."
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $csvFiles = @()
            
            # Server Information CSV
            $serverCsv = "Property,Value`n"
            $serverCsv += "Server Name,$($serverInfo.ServerName)`n"
            $serverCsv += "SQL Version,$($serverInfo.SQLVersion)`n"
            $serverCsv += "Version String,$($serverInfo.Version)`n"
            $serverCsv += "Build Number,$($serverInfo.BuildNumber)`n"
            $serverCsv += "Edition,`"$($serverInfo.Edition)`"`n"
            $serverCsv += "Product Level,$($serverInfo.ProductLevel)`n"
            $serverCsv += "Current Patch,$($serverInfo.ProductUpdateLevel)`n"
            $serverCsv += "Update Status,$($serverInfo.UpdateStatus)`n"
            $cuLink = $serverInfo.LatestCU -replace '\[|\]', ''
            $serverCsv += "Latest CU Download,$cuLink`n"
            $serverCsv += "Is Clustered,$($serverInfo.IsClustered)`n"
            $serverCsv += "HADR Enabled,$($serverInfo.IsHadrEnabled)"
            
            # Availability Groups CSV
            $agCsv = ""
            if ($allData.availabilityGroups.Count -gt 0) {
                $agCsv = "AG Name,Primary Replica,Role,Listener DNS,Listener Port,Listener IP,Replicas`n"
                foreach ($ag in $allData.availabilityGroups) {
                    $agCsv += "$($ag.Name),$($ag.PrimaryReplica),$($ag.LocalReplicaRole),$($ag.ListenerDNS),$($ag.ListenerPort),$($ag.ListenerIP),`"$($ag.Replicas)`"`n"
                }
                $agCsv = $agCsv.TrimEnd("`n")
            }
            
            # Databases CSV
            $dbCsv = ""
            if ($allData.databases.Count -gt 0) {
                $dbCsv = "Database,Data (GB),Log (GB),Total (GB),Status,Recovery Model,Owner,Connections,Last Backup,In AG`n"
                foreach ($db in $allData.databases) {
                    $dbCsv += "$($db.DatabaseName),$($db.DataSizeGB),$($db.LogSizeGB),$($db.TotalSizeGB),$($db.Status),$($db.RecoveryModel),$($db.Owner),$($db.ActiveConnections),$($db.LastFullBackup),$($db.InAvailabilityGroup)`n"
                }
                $dbCsv = $dbCsv.TrimEnd("`n")
            }
            
            # Database Users CSV
            $usersCsv = ""
            if ($allData.databaseUsers.Count -gt 0) {
                $usersCsv = "Database,User Name,Login Type,Roles,Has DB Access,Created`n"
                foreach ($user in $allData.databaseUsers) {
                    $usersCsv += "$($user.DatabaseName),$($user.UserName),$($user.LoginType),`"$($user.Roles)`",$($user.HasDBAccess),$($user.CreateDate)`n"
                }
                $usersCsv = $usersCsv.TrimEnd("`n")
            }
            
            if ($exportToFile) {
                # Write separate CSV files for each section
                $serverFile = "server_info_$($serverInfo.ServerName)_$timestamp.csv"
                $serverCsv | Out-File -FilePath $serverFile -Encoding UTF8 -NoNewline
                Write-Host "Server CSV file created: $serverFile"
                $csvFiles += @{ path = $serverFile; name = $serverFile }
                
                if ($agCsv) {
                    $agFile = "availability_groups_$($serverInfo.ServerName)_$timestamp.csv"
                    $agCsv | Out-File -FilePath $agFile -Encoding UTF8 -NoNewline
                    Write-Host "AG CSV file created: $agFile"
                    $csvFiles += @{ path = $agFile; name = $agFile }
                }
                
                if ($dbCsv) {
                    $dbFile = "databases_$($serverInfo.ServerName)_$timestamp.csv"
                    $dbCsv | Out-File -FilePath $dbFile -Encoding UTF8 -NoNewline
                    Write-Host "Databases CSV file created: $dbFile"
                    $csvFiles += @{ path = $dbFile; name = $dbFile }
                }
                
                if ($usersCsv) {
                    $usersFile = "database_users_$($serverInfo.ServerName)_$timestamp.csv"
                    $usersCsv | Out-File -FilePath $usersFile -Encoding UTF8 -NoNewline
                    Write-Host "Users CSV file created: $usersFile"
                    $csvFiles += @{ path = $usersFile; name = $usersFile }
                }
                
                # Build combined CSV content for data field
                $combinedCsv = "# Server Information`n" + $serverCsv
                if ($agCsv) { $combinedCsv += "`n`n# Availability Groups`n" + $agCsv }
                if ($dbCsv) { $combinedCsv += "`n`n# Databases`n" + $dbCsv }
                if ($usersCsv) { $combinedCsv += "`n`n# Database Users`n" + $usersCsv }
                
                # Output with file references
                Write-Output-JSON @{
                    xy = 1
                    data = $combinedCsv
                    files = $csvFiles
                }
            } else {
                # Build combined CSV for data output only
                $combinedCsv = "# Server Information`n" + $serverCsv
                if ($agCsv) { $combinedCsv += "`n`n# Availability Groups`n" + $agCsv }
                if ($dbCsv) { $combinedCsv += "`n`n# Databases`n" + $dbCsv }
                if ($usersCsv) { $combinedCsv += "`n`n# Database Users`n" + $usersCsv }
                
                Write-Output-JSON @{
                    xy = 1
                    data = $combinedCsv
                }
            }
        }
        "MD" {
            if ($exportToFile) {
                # Generate filename with timestamp
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $filename = "sqlserver_info_$($serverInfo.ServerName)_$timestamp.md"
                
                # Write Markdown to file
                $markdownContent | Out-File -FilePath $filename -Encoding UTF8 -NoNewline
                Write-Host "Markdown file created: $filename"
                
                # Output markdown content directly as data AND file reference
                $mdData = @{
                    xy = 1
                    data = $markdownContent
                    files = @(
                        @{
                            path = $filename
                            name = $filename
                        }
                    )
                }
                Write-Output-JSON $mdData
            } else {
                # Output markdown directly (no file)
                $mdData = @{
                    xy = 1
                    data = $markdownContent
                }
                Write-Output-JSON $mdData
            }
        }
        default {
            Write-Host "Unknown export format: $exportFormat, defaulting to JSON"
            $jsonData = @{
                xy = 1
                data = $allData
            }
            Write-Output-JSON $jsonData
        }
    }
    
    # Success message
    $totalDatabases = $allData.databases.Count
    $totalAGs = $allData.availabilityGroups.Count
    $totalUsers = $allData.databaseUsers.Count
    
    $summary = "Information collected successfully: $totalDatabases database(s), $totalUsers user(s)"
    if ($totalAGs -gt 0) {
        $summary += ", $totalAGs Availability Group(s)"
    }
    
    Send-Success -Description $summary
}
catch {
    Send-Error -Code 5 -Description "Error: $($_.Exception.Message)"
    exit 1
}
