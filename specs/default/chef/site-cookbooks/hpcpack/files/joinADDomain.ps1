Param
(
    [parameter(Mandatory = $true)]
    [string] $DomainName,

    [parameter(Mandatory = $true)]
    [PSCredential] $Credential,

    [parameter(Mandatory = $false)]
    [int] $RetryIntervalSeconds = 10,    

    [parameter(Mandatory = $false)]
    [int] $MaxRetryCount = 30, 

    [parameter(Mandatory = $false)]
    [string] $OuPath = "",

    [parameter(Mandatory = $false)]
    [string] $PreferredDC = "",

    [parameter(Mandatory = $false)]
    [string[]] $DnsServers = @(),

    [parameter(Mandatory = $false)]
    [string] $LogFilePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version latest
if($PSVersionTable.PSVersion -lt '3.0' -or ([System.Environment]::OSVersion.Version.Major -eq 6 -and [System.Environment]::OSVersion.Version.Minor -eq 1))
{
    Import-Module ServerManager
    $netfx35 = Get-WindowsFeature -Name Net-Framework-Core -ErrorAction SilentlyContinue
    if(($null -ne $netfx35) -and (-not $netfx35.Installed))
    {
        Add-WindowsFeature -Name NET-Framework-Core
    }
    $currentDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
else
{
    $currentDir = $PSScriptRoot
}

Import-Module $currentDir\InstallUtilities.psm1
if(!$LogFilePath)
{
    $logFolder = "C:\Windows\Temp\HPCSetupLogs"
    if(-not (Test-Path $logFolder))
    {
        New-Item -Path $logFolder -ItemType Directory -Force
    }
    $logfileName = "joinADDomain-" + [System.DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmmss") + ".txt"
    $LogFilePath =  "$logFolder\$logfileName"
}

Set-LogFile -Path $LogFilePath
$cmdLine = $MyInvocation.MyCommand.Definition
foreach($boundParam in $PSBoundParameters.GetEnumerator())
{
    if($boundParam.Key -notmatch 'Password' -and $boundParam.Key -notmatch 'Credential') {
        $cmdLine += " -$($boundParam.Key) $($boundParam.Value)"
    }
}
Write-Log $cmdLine

if($DnsServers.Count -gt 0)
{
    Write-Log "Setting DNS servers: $($DnsServers -join ', ')"
    $netWmiObj = Get-WmiObject win32_networkadapterconfiguration -filter "IPEnabled='true' AND DHCPEnabled='true'"
    $defaultGateWay = $netWmiObj.DefaultIPGateway
    $dhcpServer = $netWmiObj.DHCPServer
    $netWmiObj.SetDNSServerSearchOrder($DnsServers)
    # Somehow the DHCP Server will be unreachable due to missing route entry in route table after changing the DNS servers
    # We will add the route entry and use ipconfig /renew to update the route table
    $dhcpRouteEntries = @($(route print) | %{$_.Trim()} | ?{$_.StartsWith("$dhcpServer ") -or $_.StartsWith("0.0.0.0 ")})
    if($dhcpRouteEntries.Count -eq 0)
    {
        route add $dhcpServer mask 255.255.255.255 $defaultGateWay
        ipconfig /renew
    }
}

$userName = $Credential.UserName
if(!$userName.Contains('\') -and !$userName.Contains('@'))
{
    $domainCred = New-Object System.Management.Automation.PSCredential ("${DomainName}\$userName", $Credential.Password)
}
else 
{
    $domainCred = $Credential
}
$curDomainName = $null
$computerSystemObj = Get-WmiObject Win32_ComputerSystem
if($computerSystemObj.PartOfDomain)
{
    $maxRetries = 5
    $retry = 0
    while ($true) {
        try
        {
            $curDomainName = ([System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()).Name
            Write-Log "The computer is currently in domain $curDomainName."
            break
        }
        catch
        {
            Write-Log "Failed to fetch the domain name: $_" -LogLevel Warning
            if($retry++ -ge $maxRetries)
            {
                $curDomainName = $computerSystemObj.Domain
                Write-Log "The computer is currently in domain $curDomainName [Win32_ComputerSystem]"
                break
            }
        }
        $retryInterval = [System.Math]::Pow(2, $retry)
        Start-Sleep -Seconds $retryInterval
        ipconfig /flushdns
    }
}

if($DomainName -ne $curDomainName)
{
    if($computerSystemObj.DomainRole -ge 4)
    {
        Write-Log "The computer is a domain controller of domain $curDomainName, cannot join domain $DomainName." -LogLevel Error
    }
    Write-Log "The computer shall join domain $DomainName."
    $joinDomainArguments = @{
        DomainName = $DomainName
        Credential = $domainCred
        Confirm = $false
    }
    if($OuPath)
    {
        Write-Log "OUPath: $ouPath"
        $joinDomainArguments.Add("OUPath", $ouPath)
    }
    if($PreferredDC)
    {
        # Parameter 'Server' supported from 3.0 on
        if($PSVersionTable.PSVersion -ge '3.0')
        {
            Write-Log "PreferredDC: $preferredDC"
            $joinDomainArguments.Add("Server", $preferredDC)
        }
        else 
        {
            Write-Log "PreferredDC specified but not supported in PowerShell 2.0: $preferredDC"
        }
    }

    $retry = 0
    while ($true) {
        try {
            Write-Log "Joining domain $DomainName with the credential of $userName"
            Add-Computer @joinDomainArguments        
            break
        }
        catch {
            $csObj = Get-WmiObject Win32_ComputerSystem
            if($csObj.PartOfDomain -and ($csObj.Domain -eq $DomainName))
            {
                Write-Log "Joining domain $DomainName with the credential of $userName"
                break
            }
            if($retry++ -ge $MaxRetryCount) {
                Write-Log "Failed to join domain ${DomainName}: $($_ | Out-String)" -LogLevel Error
            }
            else {
                Write-Log "Failed to join domain ${DomainName}: $_" -LogLevel Warning                
            }
        }

        Start-Sleep -Seconds $RetryIntervalSeconds
        ipconfig /flushdns
    }
}
else {
    # Try to add the domain user as local administrator so that the domain user can still log onto this machine in case HPC Management service fail to start.
    # We ignore the failure here because it will not block the node from joining the cluster.
    try {
        $adminGroup = [ADSI]("WinNT://$env:COMPUTERNAME/administrators, group")
        $usr = $domainCred.UserName.Replace("\","/")
        $adminGroup.Add("WinNT://$usr, user")
    }
    catch {
        Write-Log "Failed to add user ${$domainCred.UserName} as local administrator: $_" -LogLevel Warning
    }
}

Write-Log "End running $($MyInvocation.MyCommand.Definition)"