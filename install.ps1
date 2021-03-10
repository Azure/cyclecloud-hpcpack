
# TODO: Should allow user to opt-out of installing python3 and use a pre-installed version
# TODO: Currently requires outbound internet to fetch python 3.7.7 and update pip

# Expects to be run from inside AUTOSCALER_HOME
# Expects to find nuget on the PATH or in JETPACK_BIN
[string]$AUTOSCALER_HOME="c:\cycle\hpcpack-autoscaler" 
[string]$JETPACK_BIN = "C:\cycle\jetpack\bin"
[string]$AUTOSCALER_VENV="c:\cycle\hpcpack-autoscaler\.venvs\cyclecloud-hpcpack"

mkdir -Force "$AUTOSCALER_HOME"

$env:Path += ";" + $JETPACK_BIN
if (-not (Test-Path "C:\cycle\python.3.7.7")) {
    nuget.exe install python -Version 3.7.7 -OutputDirectory C:\cycle\
}
if (-not (Test-Path "$AUTOSCALER_VENV")) {
    & C:\cycle\python.3.7.7\tools\python.exe -m venv $AUTOSCALER_VENV
}
& $AUTOSCALER_VENV\Scripts\Activate.ps1

 
& pip install -U pip
# & pip install urllib3 requests typeguard jsonpickle pytz
& pip install -U (get-item $PSScriptRoot\packages\*)
# & pip install -e .

@"
& $AUTOSCALER_VENV\Scripts\Activate.ps1

# Powershell will interpret stderr output as an error, so redirect
# https://stackoverflow.com/questions/2095088/error-when-calling-3rd-party-executable-from-powershell-when-using-an-ide

& python -m cyclecloud-hpcpack.autoscaler
"@ > $JETPACK_BIN\azcc_autoscale.ps1
