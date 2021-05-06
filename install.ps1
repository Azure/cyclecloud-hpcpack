
# TODO: Should allow user to opt-out of installing python3 and use a pre-installed version
# TODO: Currently requires outbound internet to fetch python 3.7.7 and update pip

# Expects to be run from inside AUTOSCALER_HOME
# Expects to find nuget on the PATH or in JETPACK_BIN
[string]$AUTOSCALER_HOME="c:\cycle\hpcpack-autoscaler" 
[string]$AUTOSCALER_BIN="$AUTOSCALER_HOME\bin"
[string]$JETPACK_BIN = "C:\cycle\jetpack\bin"
[string]$JETPACK_CONFIG = "C:\cycle\jetpack\config"
[string]$AUTOSCALER_VENV="$AUTOSCALER_HOME\.venvs\cyclecloud-hpcpack"

mkdir -Force "$AUTOSCALER_HOME"
mkdir -Force "$AUTOSCALER_BIN"

$env:Path += ";" + $JETPACK_BIN + ";" + $AUTOSCALER_BIN
if (-not (Test-Path "C:\cycle\python.3.8.8")) {
    nuget.exe install python -Version 3.8.8 -OutputDirectory C:\cycle\
}
if (-not (Test-Path "$AUTOSCALER_VENV")) {
    & C:\cycle\python.3.8.8\tools\python.exe -m venv $AUTOSCALER_VENV
}
& $AUTOSCALER_VENV\Scripts\Activate.ps1

& pip install -U pip
# & pip install urllib3 requests typeguard jsonpickle pytz
& pip install -U (get-item $PSScriptRoot\packages\*)
# & pip install -e .

# Copy the default logging config file
if (-not (Test-Path "$JETPACK_CONFIG\autoscale_logging.conf")) {
    copy $PSScriptRoot\logging.conf $JETPACK_CONFIG\autoscale_logging.conf
}

@"
& $AUTOSCALER_VENV\Scripts\Activate.ps1

# Powershell will interpret stderr output as an error, so redirect
# https://stackoverflow.com/questions/2095088/error-when-calling-3rd-party-executable-from-powershell-when-using-an-ide


& python -m cyclecloud-hpcpack.cli @args
deactivate
"@ > $AUTOSCALER_BIN\azhpcpack.ps1

# Generate the autoscaling config (only once)
if (-not (Test-Path "$JETPACK_CONFIG\autoscale.json")) {

    [string]$CLUSTER_NAME=jetpack.cmd config cyclecloud.cluster.name
    [string]$USERNAME=jetpack.cmd config cyclecloud.config.username
    [string]$PASSWORD=jetpack.cmd config cyclecloud.config.password
    [string]$URL=jetpack.cmd config cyclecloud.config.web_server
    [string]$IDLE_TIMEOUT=jetpack.cmd config cyclecloud.cluster.autoscale.idle_time_after_jobs
    [string]$BOOT_TIMEOUT=jetpack.cmd config cyclecloud.cluster.autoscale.provisioning_timeout
    [string]$VM_RETENTION=jetpack.cmd config cyclecloud.cluster.autoscale.vm_retention_days

    [string]$AUTOSTART_ENABLED=jetpack.cmd config cyclecloud.cluster.autoscale.start_enabled    
    if ($AUTOSTART_ENABLED -eq "true") {
        [string]$AUTOSTART_DISABLED=""
    } else {
        [string]$AUTOSTART_DISABLED="--disable-autostart"
    }
    
    # Important: ensure that output is ASCII or normal UTF-8 (powershell often generated UTF-16 or UTF-8-SIG)
    echo "Generating config at : $JETPACK_CONFIG\autoscale.json"
    & $AUTOSCALER_BIN\azhpcpack.ps1 initconfig --cluster-name $CLUSTER_NAME `
                                               --username $USERNAME `
                                               --password $PASSWORD `
                                               --url $URL $AUTOSTART_DISABLED `
                                               --idle-timeout $IDLE_TIMEOUT `
                                               --boot-timeout $BOOT_TIMEOUT `
                                               --vm_retention_days $VM_RETENTION `
                                               --log-config $JETPACK_CONFIG\autoscale_logging.conf  | Set-Content -Encoding ASCII $JETPACK_CONFIG\autoscale.json
}
