include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_ps"
include_recipe "hpcpack::_join-ad-domain"
include_recipe "hpcpack::_find-hn"

bootstrap_dir = node['cyclecloud']['bootstrap']
mod_dir = "#{bootstrap_dir}\\modHpcPack"
hpcpack2012_dir = "#{bootstrap_dir}\\hpcpack2012"
dsc_script = "ConfigHpcNode.ps1"
modules_dir = "C:\\Program\ Files\\WindowsPowerShell\\Modules"


#xSystemSecurity 1.3 doesn't work

directory mod_dir
directory hpcpack2012_dir


cookbook_file "#{bootstrap_dir}\\#{dsc_script}.zip" do
   source "#{dsc_script}.zip"
   action :create
end

cookbook_file "#{hpcpack2012_dir}\\SetupComplete2.mods.cmd" do
   source "hpcpack2012/SetupComplete2.mods.cmd"
   action :create
end


powershell_script 'unzip-xHpcPack' do
    code "#{bootstrap_dir}\\unzip.ps1 #{bootstrap_dir}\\#{dsc_script}.zip #{mod_dir}"
    creates "#{mod_dir}\\#{dsc_script}"
end

powershell_script 'set-dsc-InstallHpcNode' do
    code <<-EOH
    $Acl = Get-Acl "#{modules_dir}"
    Set-Acl "#{mod_dir}" $Acl
    $oModPath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath + ";" + $pwd, "Machine")
    $env:PSModulePath = $env:PSModulePath + ";" + $pwd
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $cert.Import('#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}','#{node['hpcpack']['cert']['password']}','DefaultKeySet')
    $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['ad']['admin']['password']}' -AsPlainText -Force
    $mycreds = New-Object System.Management.Automation.PSCredential ('#{node['hpcpack']['ad']['admin']['name']}', $secpasswd)
    $cd = @{
        AllNodes = @(
            @{
                NodeName = 'localhost'
                PSDscAllowPlainTextPassword = $true
                PSDscAllowDomainUser = $true
            }
        )}

    . .\\ConfigHpcNode.ps1
    ConfigHpcNode -DomainName "#{node['hpcpack']['ad']['domain']}" -RetryCount 2 -RetryIntervalSec 10 `
      -NodeType ComputeNode -HeadNodeList #{node['hpcpack']['hn']['hostname']} `
      -SSLThumbprint $cert.Thumbprint -PostConfigScript "" -AdminCreds $mycreds `
      -ConfigurationData $cd
    Start-DscConfiguration .\\ConfigHpcNode -Wait -Force -Verbose 
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath, "Machine")
    $env:PSModulePath = $oModPath
    EOH
    cwd mod_dir
    not_if '(Get-Service "HpcManagement" -ErrorAction SilentlyContinue).Status -eq "Running"'
end

# The main guard for this script is internal - it checks if clustername matches the registry setting
powershell_script "register-hpcpack2k12-node" do
  code <<-EOH
  cmd.exe /c "#{hpcpack2012_dir}\\SetupComplete2.mods.cmd" "#{node['hpcpack']['hn']['hostname']}"
  EOH
  cwd hpcpack2012_dir
  only_if 'Add-PsSnapin Microsoft.HPC; (Get-Command Get-HpcNode).Version.Major -lt 5'
end

# Also override the default method (it seemed to re-run and break the connection between HN and CN)
# file "#{ENV['SystemRoot']}\\OEM\\SetupComplete2.cmd" do
file "C:\\Windows\\OEM\\SetupComplete2.cmd" do
  content <<-EOH
cmd.exe /c "#{hpcpack2012_dir}\\SetupComplete2.mods.cmd #{node['hpcpack']['hn']['hostname']}"

EOH
end

powershell_script 'add-to-NodeTemplate' do
    code <<-EOH
    Add-PsSnapin Microsoft.HPC
    Set-Content Env:CCP_SCHEDULER "#{node['hpcpack']['hn']['hostname']}"
    $this_node = Get-HpcNode -Name (hostname) -Scheduler #{node['hpcpack']['hn']['hostname']}
    if ($this_node.HealthState -eq "Unapproved") { 
        Assign-HpcNodeTemplate -NodeName (hostname) `
            -Name "Default ComputeNode Template" -Confirm:$false `
            -Scheduler #{node['hpcpack']['hn']['hostname']}
    }
    EOH
    domain node['hpcpack']['ad']['domain']
    user node['hpcpack']['ad']['admin']['name']
    password node['hpcpack']['ad']['admin']['password']
    retries 3
    retry_delay 5
#    not_if 'Add-PsSnapin Microsoft.HPC; (Get-Command Get-HpcNode).Version.Major -lt 5'
end


powershell_script 'set-node-location' do
    code <<-EOH
    Add-PsSnapin Microsoft.HPC
    Set-Content Env:CCP_SCHEDULER "#{node['hpcpack']['hn']['hostname']}"
    $this_node = Get-HpcNode -Name (hostname) -Scheduler #{node['hpcpack']['hn']['hostname']}
    if ($this_node.Location -eq "") {
        Set-HPCNode -Name (hostname) -DataCenter #{node['cyclecloud']['node']['group_id']} `
            -Rack #{node['cyclecloud']['instance']['id']} `
            -Scheduler #{node['hpcpack']['hn']['hostname']} -Verbose
    }
    EOH
    domain node['hpcpack']['ad']['domain']
    user node['hpcpack']['ad']['admin']['name']
    password node['hpcpack']['ad']['admin']['password']
    retries 3
    retry_delay 5
end

# HPC Pack 2012 has a bug which requires nodes to be in the Offline state for several seconds before
# they can be brought online (fixed in 2016).  So sleep for a bit...
log "Waiting for HPC worker node to reach Offline state..." do level :info end
powershell_script 'wait-for-offline-state' do
    code <<-EOH
    Add-PsSnapin Microsoft.HPC
    Set-Content Env:CCP_SCHEDULER "#{node['hpcpack']['hn']['hostname']}"
    $this_node = Get-HpcNode -Name (hostname) -Scheduler #{node['hpcpack']['hn']['hostname']}

    echo "Waiting for HPC worker node to reach Offline state... Current state: $this_node.NodeState"
    $tries=0
    while ( "Offline" -ne $this_node.NodeState ) {
        $tries += 1
        if($tries -gt '10'){
            throw "Timed out waiting for Offline state.  Node $env:COMPUTERNAME is still in state: $this_node.NodeState"
        }
        start-sleep -s 10
    }
    $tries=0
    while ( "OK" -ne $this_node.HealthState ) {
        $tries += 1
        if($tries -gt '10'){
            throw "Timed out waiting for OK healthstate.  Node $env:COMPUTERNAME still shows health: $this_node.HealthState"
        }
        start-sleep -s 10
    }

    echo "Node $env:COMPUTERNAME has reached state: $this_node.NodeState.   Adding delay for HPC Pack 2012 registration issue..."
    start-sleep -s 60
    EOH
    domain node['hpcpack']['ad']['domain']
    user node['hpcpack']['ad']['admin']['name']
    password node['hpcpack']['ad']['admin']['password']
    retries 3
    retry_delay 5
    only_if "Add-PsSnapin Microsoft.HPC; 'Online' -ne (Get-HpcNode -Name (hostname) -Scheduler #{node['hpcpack']['hn']['hostname']}).NodeState  -and (Get-Command Get-HpcNode).Version.Major -lt 5"
end


defer_block "Defer bringing node Online until end of converge" do

    powershell_script 'bring-node-online' do
        code <<-EOH
        Add-PsSnapin Microsoft.HPC
        Set-Content Env:CCP_SCHEDULER "#{node['hpcpack']['hn']['hostname']}"
        $this_node = Get-HpcNode -Name (hostname) -Scheduler #{node['hpcpack']['hn']['hostname']}
        if ( "Online" -ne $this_node.NodeState ) {
            echo "Bringing HPC worker node online..."
            Set-HpcNodeState -Name (hostname) -Scheduler #{node['hpcpack']['hn']['hostname']} `
                -State Online -Verbose
        }
        EOH
        domain node['hpcpack']['ad']['domain']
        user node['hpcpack']['ad']['admin']['name']
        password node['hpcpack']['ad']['admin']['password']
        retries 3
        retry_delay 5
    end

    # Re-add the node periodically if it loses AD connectivity (TODO: why is this so common?)
    template "#{bootstrap_dir}\\bring-hpc-node-online.ps1" do
      source "bring-hpc-node-online.ps1.erb"
    end
    template "#{bootstrap_dir}\\bring-hpc-node-online-logging-wrapper.ps1" do
      source "bring-hpc-node-online-logging-wrapper.ps1.erb"
    end


    windows_task 'hpc-verify-node-online' do
        task_name "HPCNodeVerifyOnline"
        command   "powershell.exe -file #{bootstrap_dir}\\bring-hpc-node-online-logging-wrapper.ps1"
        user      "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
        password  node['hpcpack']['ad']['admin']['password']
        frequency :minute
        frequency_modifier 5
        #only_if { node['cyclecloud']['cluster']['autoscale']['start_enabled'] }
    end


end
