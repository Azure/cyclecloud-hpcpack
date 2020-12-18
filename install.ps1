
# TODO: Should allow user to opt-out of installing python3 and use a pre-installed version

# Expects to be run from inside AUTOSCALER_HOME
# Expects to find nuget on the PATH or in JETPACK_BIN
[string]$AUTOSCALER_HOME="c:\cycle\hpcpack-autoscaler" 
[string]$JETPACK_BIN = "C:\cycle\jetpack\bin"
[string]$BOOTSTRAP = "C:\cycle\jetpack\system\bootstrap"
[string]$AUTOSCALER_VENV="c:\cycle\hpcpack-autoscaler\.venvs\cyclecloud-hpcpack"

mkdir "c:\cycle"

$env:Path += ";" + $JETPACK_BIN
nuget.exe install python -Version 3.7.7 -OutputDirectory C:\cycle\
& C:\cycle\python.3.7.7\tools\python.exe -m venv $AUTOSCALER_VENV
& $AUTOSCALER_VENV\Scripts\Activate.ps1


& pip install -U pip
# & pip install urllib3 requests typeguard jsonpickle pytz
& pip install packages\*
& pip install -e .


@"
& $AUTOSCALER_VENV\Scripts\Activate.ps1

& python -m cyclecloud-hpcpack.cli  @args
"@ > $JETPACK_BIN\azcc.ps1

@"
& $AUTOSCALER_VENV\Scripts\Activate.ps1

# Powershell will interpret stderr output as an error, so redirect
# https://stackoverflow.com/questions/2095088/error-when-calling-3rd-party-executable-from-powershell-when-using-an-ide

& python -m cyclecloud-hpcpack.autoscaler 2>&1 | %{ "$_" }
"@ > $JETPACK_BIN\azcc_autoscale.ps1
