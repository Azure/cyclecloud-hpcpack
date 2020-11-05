[string]$JETPACK_BIN = "C:\cycle\jetpack\bin"
[string]$AUTOSCALER_VENV="c:\cycle\.venvs\cyclecloud-hpcpack"
[string]$BOOTSTRAP = "C:\cycle\jetpack\system\bootstrap"

& $JETPACK_BIN\nuget.exe install python -Version 3.7.7 -OutputDirectory C:\cycle\
& C:\cycle\python.3.7.7\tools\python.exe -m venv $AUTOSCALER_VENV
& $AUTOSCALER_VENV\Scripts\Activate.ps1


& pip install -U pip
& pip install urllib3 requests typeguard jsonpickle pytz
& pip install $BOOTSTRAP\cyclecloud_api-8.0.1-py2.py3-none-any.whl
& pip install $BOOTSTRAP\cyclecloud-scalelib-0.1.1.tar.gz
& pip install -e .


@"
& $AUTOSCALER_VENV\Scripts\Activate.ps1

& python -m cyclecloud-hpcpack.cli  @args
"@ > $JETPACK_BIN\azcc_autoscale_cli.ps1

@"
& $AUTOSCALER_VENV\Scripts\Activate.ps1

# Powershell will interpret stderr output as an error, so redirect
# https://stackoverflow.com/questions/2095088/error-when-calling-3rd-party-executable-from-powershell-when-using-an-ide

& python -m cyclecloud-hpcpack.autoscaler 2>&1 | %{ "$_" }
"@ > $JETPACK_BIN\azcc_autoscale.ps1
