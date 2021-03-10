include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
include_recipe "hpcpack::_find-hn"
include_recipe "hpcpack::_join-ad-domain"

bootstrap_dir = node['cyclecloud']['bootstrap']
install_dir = "#{bootstrap_dir}\\hpcpack"

directory install_dir

cookbook_file "#{bootstrap_dir}\\InstallHPCBrokerNode.ps1" do
  source "InstallHPCBrokerNode.ps1"
  action :create
end

powershell_script 'Copy-HpcPackInstaller' do
  code  <<-EOH
  $reminst = "\\\\#{node['hpcpack']['hn']['hostname']}\\REMINST"
  $retry = 0
  While($true) {
    if(Test-Path "$reminst\\Setup.exe") {
      Copy-Item -Path "$reminst\\amd64" -Destination "#{install_dir}" -Recurse -Force
      Copy-Item -Path "$reminst\\i386" -Destination "#{install_dir}" -Recurse -Force
      Copy-Item -Path "$reminst\\MPI" -Destination "#{install_dir}" -Recurse -Force
      Copy-Item -Path "$reminst\\Setup" -Destination "#{install_dir}" -Recurse -Force
      Copy-Item -Path "$reminst\\Setup.exe" -Destination "#{install_dir}" -Force
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
  user "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
  password "#{node['hpcpack']['ad']['admin']['password']}"
  not_if { ::File.exists?("#{install_dir}/Setup.exe") }
end

# Install Hpc Broker Node
# Install logs will end up in : C:\Windows\Temp\HPCSetupLogs\HPCSetupLogs*\chainer.txt
powershell_script 'install-hpcpack' do
  code <<-EOH
  $vaultName = "#{node['hpcpack']['keyvault']['vault_name']}"
  $vaultCertName = "#{node['hpcpack']['keyvault']['cert']['cert_name']}"
  if($vaultName -and $vaultCertName) {
    #{bootstrap_dir}\\InstallHPCBrokerNode.ps1 -SetupFilePath "#{install_dir}\\Setup.exe" -ClusterConnectionString #{node['hpcpack']['hn']['hostname']} -VaultName $vaultName -VaultCertName $vaultCertName
  }
  else {
    $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
    #{bootstrap_dir}\\InstallHPCBrokerNode.ps1 -SetupFilePath "#{install_dir}\\Setup.exe" -ClusterConnectionString #{node['hpcpack']['hn']['hostname']} -PfxFilePath "#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}" -PfxFilePassword $secpasswd
  }
  EOH
  only_if '$null -eq (Get-Service "HpcManagement" -ErrorAction SilentlyContinue)'
end

# Auto assign the node to "Default ComputeNode Template" and add to the node group "CycleCloudNodes"
# Ideally it shall be done in the autoscaler
powershell_script 'assign-NodeTemplate' do
    code <<-EOH
    $env:CCP_LOGROOT_USR = "%LOCALAPPDATA%\\Microsoft\\Hpc\\LogFiles\\"
    Add-PsSnapin Microsoft.HPC
    $headNodeName = "#{node['hpcpack']['hn']['hostname']}"
    Set-Content Env:CCP_SCHEDULER $headNodeName
    $nodeTemplate = $null
    $retry = 0
    while ($true) {
      $nodeTemplate = Get-HpcNodeTemplate -Name "Default BrokerNode Template" -Scheduler $headNodeName -ErrorAction SilentlyContinue
      if($null -ne $nodeTemplate) {
        break
      }
      if($retry++ -lt 60) {
        Start-Sleep -Seconds 10
      } else {
        break
      }
    }

    if($null -ne $nodeTemplate) {
      $retry = 0
      $this_node = Get-HpcNode -Name $env:COMPUTERNAME -Scheduler $headNodeName -ErrorAction SilentlyContinue
      while ($null -eq $this_node) {
        if($retry++ -lt 5) {
          Start-Sleep -Seconds 10
          $this_node = Get-HpcNode -Name $env:COMPUTERNAME -Scheduler $headNodeName -ErrorAction SilentlyContinue
        } else {
          throw "Node not shown in the HPC cluster."
        }
      }
      if ($this_node.HealthState -eq "Unapproved") {
          Assign-HpcNodeTemplate -NodeName $env:COMPUTERNAME -Name "Default BrokerNode Template" -Confirm:$false -Scheduler $headNodeName
      }
    }
    EOH
    domain node['hpcpack']['ad']['domain']
    user node['hpcpack']['ad']['admin']['name']
    password node['hpcpack']['ad']['admin']['password']
    retries 2
    retry_delay 5
end
