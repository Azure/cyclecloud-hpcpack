include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
include_recipe "hpcpack::_find-hn"
include_recipe "hpcpack::_join-ad-domain"

bootstrap_dir = node['cyclecloud']['bootstrap']
install_dir = "#{bootstrap_dir}\\hpcpack"

directory install_dir

jetpack_download node['hpcpack']['cn']['installer_filename'] do
  project "hpcpack"
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cn']['installer_filename']}") }
end

powershell_script 'unzip-HpcPackInstaller' do
  code "#{bootstrap_dir}\\unzip.ps1 #{node['jetpack']['downloads']}/#{node['hpcpack']['cn']['installer_filename']} #{install_dir}"
  creates "#{install_dir}\\InstallHPCComputeNode.ps1"
  only_if '$null -eq (Get-Service "HpcManagement" -ErrorAction SilentlyContinue)'
end


# Set the cycle instance Id in environment variable CCP_LOGROOT_USR
env 'CCP_LOGROOT_USR' do
  value "%LOCALAPPDATA%\\Microsoft\\Hpc\\LogFiles\\"
  only_if '$null -eq (Get-Service "HpcManagement" -ErrorAction SilentlyContinue)'
end

# Install Hpc Compute Node
# Install logs will end up in : C:\Windows\Temp\HPCSetupLogs\HPCSetupLogs*\chainer.txt
powershell_script 'install-hpcpack' do
  code <<-EOH
  $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
  #{install_dir}\\InstallHPCComputeNode.ps1 -ClusterConnectionString #{node['hpcpack']['hn']['hostname']} -PfxFilePath "#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}" -PfxFilePassword $secpasswd
  EOH
  only_if '$null -eq (Get-Service "HpcManagement" -ErrorAction SilentlyContinue)'
end

# Auto assign the node to "Default ComputeNode Template" and add to the node group "CycleCloudNodes"
# Ideally it shall be done in the autoscaler
powershell_script 'assign-NodeTemplate' do
    code <<-EOH
    Add-PsSnapin Microsoft.HPC
    $headNodeName = "#{node['hpcpack']['hn']['hostname']}"
    Set-Content Env:CCP_SCHEDULER $headNodeName
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
        Assign-HpcNodeTemplate -NodeName $env:COMPUTERNAME -Name "Default ComputeNode Template" -Confirm:$false -Scheduler $headNodeName
    }
    EOH
    domain node['hpcpack']['ad']['domain']
    user node['hpcpack']['ad']['admin']['name']
    password node['hpcpack']['ad']['admin']['password']
    retries 2
    retry_delay 5
end
