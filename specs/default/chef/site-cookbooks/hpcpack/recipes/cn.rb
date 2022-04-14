include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
include_recipe "hpcpack::_find-hn"
include_recipe "hpcpack::_join-ad-domain"
include_recipe "hpcpack::_install_dotnetfx"

bootstrap_dir = node['cyclecloud']['bootstrap']
install_dir = "#{bootstrap_dir}\\hpcpack"

directory install_dir

cookbook_file "#{bootstrap_dir}\\InstallHPCComputeNode.ps1" do
  source "InstallHPCComputeNode.ps1"
  action :create
end

jetpack_download node['hpcpack']['cn']['installer_filename'] do
  project "hpcpack"
  ignore_failure true
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cn']['installer_filename']}") || ::File.exists?("#{install_dir}/HpcCompute_x64.msi") || ::File.exists?("#{install_dir}/Setup.exe")}
end

# Allow either basic CN installer or full installer
powershell_script 'unzip-HpcPackInstaller' do
  code <<-EOH
  #{bootstrap_dir}\\unzip.ps1 #{node['jetpack']['downloads']}/#{node['hpcpack']['cn']['installer_filename']} #{install_dir}
  if(Test-Path "#{install_dir}\\HpcCompute_x64.msi") {
    echo "Installing #{install_dir}\\HpcCompute_x64.msi"
  }
  elseif(Test-Path "#{install_dir}\\setup\\HpcCompute_x64.msi") {
    Copy-Item -Path "#{install_dir}\\amd64\\SSCERuntime_x64-ENU.exe" -Destination "#{install_dir}" -Force
    Copy-Item -Path "#{install_dir}\\MPI\\MSMpiSetup.exe" -Destination "#{install_dir}" -Force
    Copy-Item -Path "#{install_dir}\\setup\\HpcCompute_x64.msi" -Destination "#{install_dir}" -Force
  }
  elseif(Test-Path "#{install_dir}\setup.exe") {
    echo "Assuming HPC Pack 2016 installer..."
  }
  else {
    throw "Invalid Compute Node installer downloaded.  Neither HpcCompute_x64.msi nor Setup.exe was found."
  }
  EOH
  creates "#{install_dir}\\HpcCompute_x64.msi"
  ignore_failure true
  not_if { ::File.exists?("#{install_dir}/HpcCompute_x64.msi")}
end

# If we failed to download HpcPackInstaller, we will try to copy from head node
powershell_script 'Copy-HpcPackInstaller' do
  code  <<-EOH
  $reminst = "\\\\#{node['hpcpack']['hn']['hostname']}\\REMINST"
  $retry = 0
  While($true) {
    if(Test-Path "$reminst\\Setup.exe") {
      if(Test-Path "$reminst\\Setup\\HpcCompute_x64.msi") {
        Copy-Item -Path "$reminst\\amd64\\SSCERuntime_x64-ENU.exe" -Destination "#{install_dir}" -Force
        Copy-Item -Path "$reminst\\MPI\\MSMpiSetup.exe" -Destination "#{install_dir}" -Force
        Copy-Item -Path "$reminst\\Setup\\HpcCompute_x64.msi" -Destination "#{install_dir}" -Force
      }
      else {
        New-Item "#{install_dir}\\amd64" -ItemType Directory -Force
        New-Item "#{install_dir}\\i386" -ItemType Directory -Force
        New-Item "#{install_dir}\\MPI" -ItemType Directory -Force
        New-Item "#{install_dir}\\Setup" -ItemType Directory -Force
        Copy-Item -Path "$reminst\\amd64\\*" -Destination "#{install_dir}\\amd64" -Force
        Copy-Item -Path "$reminst\\i386\\vcredist_x86.exe" -Destination "#{install_dir}\\i386\\" -Force
        Copy-Item -Path "$reminst\\MPI\\*" -Destination "#{install_dir}\\MPI" -Force
        Copy-Item -Path "$reminst\\Setup\\*" -Destination "#{install_dir}\\Setup" -Recurse -Force -Exclude @('*_x86.msi', 'HpcKsp*')
        Copy-Item -Path "$reminst\\Setup.exe" -Destination "#{install_dir}" -Force
      }
      break
    }
    elseif($retry++ -lt 50) {
      start-sleep -seconds 20
    }
    else {
      throw "head node not available"
    }
  }
  EOH
  creates "#{install_dir}\\Setup.exe"
  not_if { ::File.exists?("#{install_dir}/HpcCompute_x64.msi") || ::File.exists?("#{install_dir}/Setup.exe")}
end

# Install Hpc Compute Node
# Install logs will end up in : C:\Windows\Temp\HPCSetupLogs\HPCSetupLogs*\chainer.txt
powershell_script 'install-hpcpack' do
  code <<-EOH
  $vaultName = "#{node['hpcpack']['keyvault']['vault_name']}"
  $vaultCertName = "#{node['hpcpack']['keyvault']['cert']['cert_name']}"
  $setupFilePath = "#{install_dir}\\HpcCompute_x64.msi"
  if(!(Test-Path $setupFilePath)) {
    $setupFilePath = "#{install_dir}\\Setup.exe"
  }
  if($vaultName -and $vaultCertName) {
    #{bootstrap_dir}\\InstallHPCComputeNode.ps1 -SetupFilePath $setupFilePath -ClusterConnectionString #{node['hpcpack']['hn']['hostname']} -VaultName $vaultName -VaultCertName $vaultCertName
  }
  else {
    $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
    #{bootstrap_dir}\\InstallHPCComputeNode.ps1 -SetupFilePath $setupFilePath -ClusterConnectionString #{node['hpcpack']['hn']['hostname']} -PfxFilePath "#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}" -PfxFilePassword $secpasswd
  }
  EOH
  not_if <<-EOH
  $hpcRegValues = Get-Item HKLM:\\SOFTWARE\\Microsoft\\HPC -ErrorAction SilentlyContinue | Get-ItemProperty | Select-Object -Property ClusterConnectionString
  ($hpcRegValues -and ($hpcRegValues.ClusterConnectionString -eq "#{node['hpcpack']['hn']['hostname']}"))
  EOH
end

# Auto assign the node to "Default ComputeNode Template" and add to the node group "CycleCloudNodes"
# Ideally it shall be done in the autoscaler
powershell_script 'assign-NodeTemplate' do
    code <<-EOH
    $env:CCP_LOGROOT_USR = "%LOCALAPPDATA%\\Microsoft\\Hpc\\LogFiles\\"
    Add-PsSnapin Microsoft.HPC
    $headNodeName = "#{node['hpcpack']['hn']['hostname']}"
    Set-Content Env:CCP_SCHEDULER $headNodeName
    $retry = 0
    $this_node = Get-HpcNode -Name $env:COMPUTERNAME -Scheduler $headNodeName -ErrorAction SilentlyContinue
    while ($null -eq $this_node) {
      if($retry++ -lt 20) {
        Start-Sleep -Seconds 3
        $this_node = Get-HpcNode -Name $env:COMPUTERNAME -Scheduler $headNodeName -ErrorAction SilentlyContinue
      } else {
        throw "Node not shown in the HPC cluster."
      }
    }
    if ($this_node.HealthState -eq "Unapproved") {
        Assign-HpcNodeTemplate -NodeName $env:COMPUTERNAME -Name "Default ComputeNode Template" -Confirm:$false -Scheduler $headNodeName
    }
    EOH
    domain node['hpcpack']['ad']['domain']
    user node['hpcpack']['ad']['admin']['name']
    password node['hpcpack']['ad']['admin']['password']
    retries 2
    retry_delay 5
end
