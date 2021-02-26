<#
    The script to install HPC Pack head node
    Author :  Microsoft HPC Pack team
    Version:  1.0
#>
Param
(
    [parameter(Mandatory = $true)]
    [string] $ClusterName,

    [parameter(Mandatory = $true, ParameterSetName='SSLThumbprint')]
    [string] $SSLThumbprint,

    [parameter(Mandatory = $true, ParameterSetName='PfxFilePath')]
    [string] $PfxFilePath,

    [parameter(Mandatory = $true, ParameterSetName='PfxFilePath')]
    [securestring] $PfxFilePassword,

    [parameter(Mandatory = $true, ParameterSetName='KeyVaultCertificate')]
    [string] $VaultName,

    [parameter(Mandatory = $true, ParameterSetName='KeyVaultCertificate')]
    [string] $VaultCertName,

    [parameter(Mandatory = $true)]
    [System.Management.Automation.PSCredential] $SetupCredential,

    [parameter(Mandatory = $false)]
    [string] $SetupFilePath = "",
    
    [parameter(Mandatory = $false)]
    [string] $SQLServerInstance = "",

    [parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential] $SQLCredential,
    
    [Parameter(Mandatory=$false)]
    [Boolean] $EnableBuiltinHA = $false
)

function AddHPCPshModules
{
    $hpcModule = Get-Module -Name ccppsh -ErrorAction SilentlyContinue -Verbose:$false
    if($null -eq $hpcModule)
    {
        $ccpPshDll = [System.IO.Path]::Combine([System.Environment]::GetEnvironmentVariable("CCP_HOME", "Machine"), "Bin\ccppsh.dll")
        Import-Module $ccpPshDll -ErrorAction Stop -Verbose:$false | Out-Null
        $curEnvPaths = $env:Path -split ';'
        $machineEnvPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
        $env:Path = ($curEnvPaths + $machineEnvPath | Select-Object -Unique) -join ';'
    }
}

# Must disable Progress bar
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
Set-StrictMode -Version latest
Import-Module $PSScriptRoot\InstallUtilities.psm1
$logFolder = "C:\Windows\Temp\HPCSetupLogs"
if(-not (Test-Path $logFolder))
{
    New-Item -Path $logFolder -ItemType Directory -Force
}
$logfileName = "installhn-" + [System.DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmmss") + ".txt"
Set-LogFile -Path "$logFolder\$logfileName"

$cmdLine = $PSCommandPath
foreach($boundParam in $PSBoundParameters.GetEnumerator())
{
    if($boundParam.Key -notmatch 'Password' -and $boundParam.Key -notmatch 'Credential') {
        $cmdLine += " -$($boundParam.Key) $($boundParam.Value)"
    }
}
Write-Log $cmdLine

if(-not $SetupFilePath)
{    
    if(Test-Path "C:\HPCPack2019\Setup.exe" -PathType Leaf) 
    {
        $SetupFilePath = "C:\HPCPack2019\Setup.exe"
    }
    elseif (Test-Path "C:\HPCPack2016\Setup.exe" -PathType Leaf) 
    {
        $SetupFilePath = "C:\HPCPack2016\Setup.exe"
    }
    else
    {
        Write-Log "Cannot found HPC Pack setup package" -LogLevel Error
    }
}
elseif (!(Test-Path -Path $SetupFilePath -PathType Leaf)) 
{
    Write-Log "HPC Pack setup package not found: $SetupFilePath" -LogLevel Error
}

### Import the certificate
if($PsCmdlet.ParameterSetName -eq "PfxFilePath")
{
    if (!(Test-Path -Path $PfxFilePath -PathType Leaf)) 
    {
        Write-Log "The PFX certificate file doesn't exist: $PfxFilePath" -LogLevel Error
    }
    try {
        $pfxCert = Import-PfxCertificate -FilePath $PfxFilePath -Password $PfxFilePassword -CertStoreLocation Cert:\LocalMachine\My -Exportable
        $SSLThumbprint = $pfxCert.Thumbprint        
    }
    catch {
        
    }
}
elseif($PsCmdlet.ParameterSetName -eq "KeyVaultCertificate")
{
    Write-Log "Install certificate $VaultCertName from key vault $VaultName"
    try {
        $pfxCert = Install-KeyVaultCertificate -VaultName $VaultName -CertName $VaultCertName -CertStoreLocation Cert:\LocalMachine\My -Exportable
        $SSLThumbprint = $pfxCert.Thumbprint        
    }
    catch {
        Write-Log "Failed to install certificate $VaultCertName from key vault $VaultName : $_" -LogLevel Error
    }
}
else 
{
    $pfxCert = Get-Item Cert:\LocalMachine\My\$SSLThumbprint -ErrorAction SilentlyContinue
    if($null -eq $pfxCert)
    {
        Write-Log "The certificate Cert:\LocalMachine\My\$SSLThumbprint doesn't exist" -LogLevel Error
    }    
}

if($pfxCert.Subject -eq $pfxCert.Issuer)
{
    if(-not (Test-Path Cert:\LocalMachine\Root\$SSLThumbprint))
    {
        Write-Log "Installing self-signed HPC communication certificate to Cert:\LocalMachine\Root\$SSLThumbprint"
        $cerFileName = "$env:Temp\HpcPackComm.cer"
        Export-Certificate -Cert "Cert:\LocalMachine\My\$SSLThumbprint" -FilePath $cerFileName | Out-Null
        Import-Certificate -FilePath $cerFileName -CertStoreLocation Cert:\LocalMachine\Root  | Out-Null
        Remove-Item $cerFileName -Force -ErrorAction SilentlyContinue
    }
}

$hpcVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($SetupFilePath)
if($hpcVersion.FileVersionRaw -lt '5.3')
{
    Write-Log "The HPC Pack version $($hpcVersion.FileVersionRaw) is not supported." -LogLevel Error
}

$defaultLocalDB = $false
if(-not $SQLServerInstance -or $SQLServerInstance -eq ".\ComputeCluster" -or $SQLServerInstance -eq "$env:COMPUTERNAME\ComputeCluster")
{
    $defaultLocalDB = $true
}

if($defaultLocalDB)
{
    $sqlServices = @('SQLBrowser', 'MSSQL$COMPUTECLUSTER', 'SQLTELEMETRY$COMPUTECLUSTER')
    foreach($svc in $sqlServices)
    {
        Write-Log "Starting service $svc"
        Set-Service -Name $svc -StartupType Automatic
        Restart-Service -Name $svc -Force
    }
}

$setupArgs = "-unattend -Quiet -HeadNode -ClusterName:$ClusterName -SSLThumbprint:$SSLThumbprint"
if($SQLServerInstance)
{
    if($PSBoundParameters.ContainsKey('SQLCredential'))
    {
        $secinfo = "Integrated Security=False;User ID={0};Password={1}" -f $SQLCredential.UserName, $SQLCredential.GetNetworkCredential().Password
    }
    else
    {
        $secinfo = "Integrated Security=True"
    }

    $mgmtConstr = "Data Source=$SQLServerInstance;Initial Catalog=HpcManagement;$secinfo"
    $schdConstr = "Data Source=$SQLServerInstance;Initial Catalog=HpcScheduler;$secinfo"
    $monConstr  = "Data Source=$SQLServerInstance;Initial Catalog=HPCMonitoring;$secinfo"
    $rptConstr  = "Data Source=$SQLServerInstance;Initial Catalog=HPCReporting;$secinfo"
    $diagConstr = "Data Source=$SQLServerInstance;Initial Catalog=HPCDiagnostics;$secinfo"
    $setupArgs += " -MgmtDbConStr:`"$mgmtConstr`" -SchdDbConStr:`"$schdConstr`" -RptDbConStr:`"$rptConstr`" -DiagDbConStr:`"$diagConstr`" -MonDbConStr:`"$monConstr`""
    if($hpcVersion.FileMajorPart -eq 6)
    {
        $haStorageConstr  = "Data Source=$SQLServerInstance;Initial Catalog=HPCHAStorage;$secinfo"
        $haWitnessConstr = "Data Source=$SQLServerInstance;Initial Catalog=HPCHAWitness;$secinfo"
        $setupArgs += " -HAStorageDbConStr:`"$haStorageConstr`" -HAWitnessDbConStr:`"$haWitnessConstr`"" 
    }
}

if(($hpcVersion.FileMajorPart -eq 6) -and $EnableBuiltinHA)
{
    $setupArgs += " -EnableBuiltinHA"
}

$retry = 0
$maxRetryTimes = 20
$maxRetryInterval = 60
$exitCode = 1
while($true)
{
    Write-Log "Installing HPC Pack Head Node"
    $p = Start-Process -FilePath $SetupFilePath -ArgumentList $setupArgs -PassThru -Wait
    $exitCode = $p.ExitCode
    if($exitCode -eq 0)
    {
        Write-Log "Succeed to Install HPC Pack Head Node"
        break
    }
    if($exitCode -eq 3010)
    {
        $exitCode = 0
        Write-Log "Succeed to Install HPC Pack Head Node, a reboot is required."
        break
    }

    if($retry++ -lt $maxRetryTimes)
    {
        $retryInterval = [System.Math]::Min($maxRetryInterval, $retry * 10)
        Write-Warning "Failed to Install HPC Pack Head Node (errCode=$exitCode), retry after $retryInterval seconds..."            
        Clear-DnsClientCache
        Start-Sleep -Seconds $retryInterval
    }
    else
    {
        if($exitCode -eq 13818)
        {
            Write-Log "Failed to Install HPC Pack Head Node (errCode=$exitCode): the certificate doesn't meet the requirements." -LogLevel Error
        }
        else
        {
            Write-Log "Failed to Install HPC Pack Head Node (errCode=$exitCode)" -LogLevel Error
        }
    }
}

AddHPCPshModules  | Out-Null
$retry = 0
while($true)
{
    try
    {
        # Get-HpcNetworkTopology will throw exception anyway if failed to connect to management service, we will retry in this case
        Get-HpcClusterRegistry -ErrorAction Stop  | Out-Null
        break
    }
    catch
    {
        if($retry++ -ge $maxRetryTimes)
        {
            Write-Log "HPC Cluster is not ready after $maxRetryTimes connection attempts: $($_ | Out-String)" -LogLevel Error
        }
        else
        {
            $RetryIntervalSec = [Math]::Ceiling($retry/10) * 10
            Write-Log "HPC Cluster is not ready yet, wait for $RetryIntervalSec seconds ..." -LogLevel Warning
            Start-Sleep -Seconds $RetryIntervalSec
        }
    }
}

Write-Log "Set HPC Network topology to Enterprise"
$nic = Get-WmiObject win32_networkadapterconfiguration -filter "IPEnabled='true' AND DHCPEnabled='true'" | Select-Object -First(1)
if ($null -eq $nic)
{
    Write-Log "Cannot find a suitable network adapter for enterprise topology" -LogLevel Error
}

$retry = 0
while($true)
{
    try
    {
        Set-HpcNetwork -Topology 'Enterprise' -Enterprise $nic.Description -EnterpriseFirewall $true -ErrorAction Stop
        break
    }
    catch
    {
        if($retry++ -ge $maxRetryTimes)
        {
            Write-Log "Failed to set HPC network topology: $($_ | Out-String)" -LogLevel Error
        }
        else
        {
            $RetryIntervalSec = [Math]::Ceiling($retry/10) * 10
            Write-Log "Failed to set HPC network topology, maybe the cluster is not ready yet, wait for $RetryIntervalSec seconds and retry ..."  -LogLevel Warning
            Start-Sleep -Seconds $RetryIntervalSec
        }
    }
}


$retry = 0
Write-Log "Setting HPC Setup User Credential"
while($true)
{
    try
    {
        Set-HpcClusterProperty -InstallCredential $SetupCredential -ErrorAction Stop
        break
    }
    catch
    {
        if($retry++ -ge $maxRetryTimes)
        {
            Write-Log "Failed to set Setup User Credential: $_" -LogLevel Error
        }
        else
        {
            $RetryIntervalSec = [Math]::Ceiling($retry/10) * 10
            Write-Log "Failed to set Setup User Credential, wait for $RetryIntervalSec seconds ..."  -LogLevel Warning
            Start-Sleep -Seconds $RetryIntervalSec
        }
    }
}

$retry = 0
$nodenaming = 'AzureVMCN-%1000%'
Write-Log "Setting Node naming series to $nodenaming"
while($true)
{
    try
    {
        Set-HpcClusterProperty -NodeNamingSeries $nodenaming -ErrorAction Stop
        break
    }
    catch
    {
        if($retry++ -ge $maxRetryTimes)
        {
            Write-Log "Failed to set NodeNamingSeries: $_" -LogLevel Error
        }
        else
        {
            $RetryIntervalSec = [Math]::Ceiling($retry/10) * 10
            Write-Log "Failed to set NodeNamingSeries, wait for $RetryIntervalSec seconds ..."  -LogLevel Warning
            Start-Sleep -Seconds $RetryIntervalSec
        }
    }
}

Write-Log "End running $($MyInvocation.MyCommand.Definition)"