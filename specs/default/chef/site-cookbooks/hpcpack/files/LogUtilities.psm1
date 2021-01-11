<#

Generic utilities for the HPC Compute Node extension

NOTE:
    This module is used by the install/enable script, and must run on 
    PowerShell 2.0 or later. 
#>

$ErrorActionPreference = 'stop'
Set-StrictMode -Version latest
$Script:LogFile = $null

function Set-LogFile
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $Script:LogFile = $Path
}

function Write-Log
{
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory=$false, Position=1)]
        [ValidateSet("Error","Warning","Information","Detail")]
        [string]$LogLevel = "Information"
    )

    $formattedMessage = '[{0:s}][{1}] {2}' -f ([DateTimeOffset]::Now.ToString('u')), $LogLevel, $Message
    Write-Verbose -Verbose "${formattedMessage}"
    if($Script:LogFile)
    {
        try
        {
            $formattedMessage | Out-File $Script:LogFile -Append
        }
        catch
        {
        }
    }
}

function DownloadFile
{
    param(
        [parameter(Mandatory = $true)]
        [string] $SourceUrl,

        [parameter(Mandatory = $true)]
        [string] $DestPath,

        [parameter(Mandatory = $false)]
        [ValidateRange(1, 60)]
        [int] $Retry = 5,

        [parameter(Mandatory = $false)]
        [ValidateRange(1, 60)]
        [int] $RetryInterval = 5
    )

    $Downloader = New-Object System.Net.WebClient
    $fileName = $($SourceUrl -split '/')[-1]
    if(Test-Path -Path $DestPath -PathType Container)
    {
        $DestPath = [IO.Path]::Combine($DestPath, $fileName)
    }

    $downloadRetry = 0
    while($true)
    {
        try
        {
            if(Test-Path -Path $DestPath)
            {
                Remove-Item -Path $DestPath -Force -Confirm:$false -ErrorAction SilentlyContinue
            }

            $Downloader.DownloadFile($SourceUrl, $DestPath)
            break
        }
        catch
        {
            if($downloadRetry -lt $Retry)
            {
                Write-Log "Failed to download from $SourceUrl, retry after $RetryInterval seconds: $_" -LogLevel Warning
                ipconfig /flushdns
                Start-Sleep -Seconds $RetryInterval
                $downloadRetry++
            }
            else
            {
               throw "Failed to download from $SourceUrl : $_"
            }
        }
    }
}

Export-ModuleMember `
    -Function @(
            'Set-LogFile'
            'Write-Log'
            'DownloadFile'
            )