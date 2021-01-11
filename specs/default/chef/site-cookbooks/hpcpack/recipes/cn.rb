include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
include_recipe "hpcpack::_find-hn"
include_recipe "hpcpack::_join-ad-domain"

bootstrap_dir = node['cyclecloud']['bootstrap']
install_dir = "#{bootstrap_dir}\\hpcpack"

directory install_dir

# Set the cycle instance Id in environment variable HPC_NodeCustomProperties
powershell_script 'set-instance-id-env-var' do
  code <<-EOH
  [System.Environment]::SetEnvironmentVariable('HPC_NodeCustomProperties', '#{node['cyclecloud']['instance']['id']}', 'Machine')
  EOH
end

jetpack_download node['hpcpack']['cn']['installer_filename'] do
  project "hpcpack"
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cn']['installer_filename']}") }
end

powershell_script 'unzip-HpcPackInstaller' do
  code "#{bootstrap_dir}\\unzip.ps1 #{node['jetpack']['downloads']}/#{node['hpcpack']['cn']['installer_filename']} #{install_dir}"
  creates "#{install_dir}\\InstallHPCComputeNode.ps1"
  not_if '(Get-Service "HpcManagement" -ErrorAction SilentlyContinue).Status -eq "Running"'
end


# Install Hpc Compute Node
# Install logs will end up in : C:\Windows\Temp\HPCSetupLogs\HPCSetupLogs*\chainer.txt
powershell_script 'install-hpcpack' do
  code <<-EOH
  $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
  #{install_dir}\\InstallHPCComputeNode.ps1 -ClusterConnectionString #{node['hpcpack']['hn']['hostname']} -PfxFilePath "#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}" -PfxFilePassword $secpasswd
  EOH
  not_if '(Get-Service "HpcManagement" -ErrorAction SilentlyContinue).Status -eq "Running"'
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
        if($tries -gt '1'){
            throw "Timed out waiting for Offline state.  Node $env:COMPUTERNAME is still in state: $this_node.NodeState"
        }
        start-sleep -s 10
    }

    echo "Node $env:COMPUTERNAME has reached state: $this_node.NodeState.   Adding delay for HPC Pack 2012 registration issue..."
    start-sleep -s 10
    EOH
    domain node['hpcpack']['ad']['domain']
    user node['hpcpack']['ad']['admin']['name']
    password node['hpcpack']['ad']['admin']['password']
    retries 10
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
