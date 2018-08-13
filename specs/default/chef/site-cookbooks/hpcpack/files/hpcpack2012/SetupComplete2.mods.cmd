@echo on
rem This script is derived from %SystemRoot%\OEM\SetupComplete2.cmd
rem It updates the HPC cluster name for Azure VMs started by CycleCloud
rem The only difference is that it takes the clustername from an argument instead of the
rem    custom data file on the image (used by ARM deployments): %SYSTEMDRIVE%\AzureData\CustomData.bin
rem TODO:
rem    There appears to be a way to update the CustomData.bin file and rerun the original script

SETLOCAL enabledelayedexpansion

set ClusName=%1

set HPCSetupLog=SetupComplete2.mods.log

@echo SetupComplete2 for HPC customized CN/BN image > %HPCSetupLog%

@echo ClusterName is %ClusName% >> %HPCSetupLog%
if "%ClusName%" == "" goto :ExitNoUpdate

@echo %ClusName%| findstr /ri "^[a-z][a-z0-9-]*[a-z0-9]$" || goto :ExitInvalidClusterName

reg query "HKLM\SOFTWARE\Microsoft\HPC" >nul || goto :ExitNotHPCCNOrBN

rem get current cluster name
set CurClusName=
for /f "tokens=2,*" %%a in ('reg query HKLM\Software\Microsoft\HPC /v ClusterName ^| find "ClusterName"') do set CurClusName=%%b
if /i "%CurClusName%" == "%ClusName%" goto :ExitNoUpdate

rem get installed role
set HPCRoles=
for /f "tokens=2,*" %%a in ('reg query HKLM\Software\Microsoft\HPC /v InstalledRole ^| find "InstalledRole"') do set HPCRoles=%%b

rem exit if this is a head node, should not enter into branch
if /i not "%HPCRoles%" == "%HPCRoles:HN=%" goto :ExitNotHPCCNOrBN

rem check whether this is a BN or CN
set IsBN=
if /i not "%HPCRoles%" == "%HPCRoles:BN=%" (
    @echo This machine is a broker node >> %HPCSetupLog%
    set IsBN=1
) else (
    @echo This machine is a compute node >> %HPCSetupLog%    
)

rem update registry keys
@echo Updating registry keys >> %HPCSetupLog%
reg add "HKLM\SOFTWARE\Microsoft\HPC" /f /v "ClusterName" /t REG_SZ /d "%ClusName%"  >> %HPCSetupLog% 2>&1
reg query "HKLM\SOFTWARE\Wow6432Node\Microsoft\HPC" >nul && reg add "HKLM\SOFTWARE\Wow6432Node\Microsoft\HPC" /f /v "ClusterName" /t REG_SZ /d "%ClusName%"  >> %HPCSetupLog% 2>&1

rem set machine env
@echo Setting environment variables >> %HPCSetupLog%
setx CCP_SCHEDULER %ClusName% /m >> %HPCSetupLog% 2>&1

rem check whether hpc services need restart
set HpcMgmtStopped=
set HpcNMStopped=
set HpcMonStopped=
set HpcBrokerStopped=
sc query HpcManagement | find "STATE" | find "STOPPED" >nul && set "HpcMgmtStopped=1" && @echo HpcManagment service not started. >> %HPCSetupLog%
sc query HpcNodeManager | find "STATE" | find "STOPPED" >nul && set "HpcNMStopped=1" && @echo HpcNodeManager service not started. >> %HPCSetupLog%
sc query HpcMonitoringClient | find "STATE" | find "STOPPED" >nul && set "HpcMonStopped=1" && @echo HpcMonitoringClient service not started. >> %HPCSetupLog%
if "%IsBN%"=="1" (
    sc query HpcBroker | find "STATE" | find "STOPPED" >nul && set "HpcBrokerStopped=1" && @echo HpcBroker service not started. >> %HPCSetupLog%
)

rem restarting hpc services
if not "%HpcMgmtStopped%"=="1" (
    @echo Restarting HpcManagement service ... >> %HPCSetupLog%
    net stop HpcManagement >> %HPCSetupLog% 2>&1
    net start HpcManagement >> %HPCSetupLog% 2>&1
)

if not "%HpcNMStopped%"=="1" (
    @echo Restarting HpcNodeManager service ... >> %HPCSetupLog%
    net stop HpcNodeManager >> %HPCSetupLog% 2>&1
    net start HpcNodeManager >> %HPCSetupLog% 2>&1
)

if not "%HpcMonStopped%"=="1" (
    @echo Restarting HpcMonitoringClient service ... >> %HPCSetupLog%
    net stop HpcMonitoringClient >> %HPCSetupLog% 2>&1
    net start HpcMonitoringClient >> %HPCSetupLog% 2>&1
) 

if "%IsBN%"=="1" if not "%HpcBrokerStopped%"=="1" (
    @echo Restarting HpcBroker service ... >> %HPCSetupLog%
    net stop HpcBroker >> %HPCSetupLog% 2>&1
    net start HpcBroker >> %HPCSetupLog% 2>&1
)

@echo Done to update the HPC cluster name. >> %HPCSetupLog%

ENDLOCAL
exit /b 0

:ExitNoUpdate
@echo 'HPCClusterName' not specified or not changed. >> %HPCSetupLog%
exit /b 0

:ExitInvalidClusterName
@echo The value of 'HPCClusterName' is invalid. >> %HPCSetupLog%
exit /b -1

:ExitNotHPCCNOrBN
@echo This machine is not a valid HPC compute node or broker node.>> %HPCSetupLog%
exit /b -1

:TrimString
rem %~1 [In, Out] The string
rem %~2 [In, Opt] The maximum possible length of the string, the default value is 100
setlocal enabledelayedexpansion
call set string=%%%~1%%
set maxLen=%~2
if "%maxLen%"=="" set maxLen=100
for /f "tokens=* delims= " %%a in ("%string%") do set string=%%a
for /l %%a in (1,1,%maxLen%) do if "!string:~-1!"==" " set string=!string:~0,-1!
ENDLOCAL & SET "%~1=%string%"
exit /b
