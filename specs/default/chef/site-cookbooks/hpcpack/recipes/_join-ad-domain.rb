include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_ps"
bootstrap_dir = node['cyclecloud']['bootstrap']
modules_dir = "C:\\Program\ Files\\WindowsPowerShell\\Modules"

reboot_required = false
ruby_block "set_reboot_required" do
  block do
    reboot_required = true
  end
  action :nothing
end

# Ensure that the local User has the same password as the AD User 
user node['hpcpack']['ad']['admin']['name'] do
  password node['hpcpack']['ad']['admin']['password']
end


# Ensure that the local User is a local Admin 
group "Administrators" do
  action :modify
  members node['hpcpack']['ad']['admin']['name']
  append true
end


mod_dir = "#{bootstrap_dir}\\joinAD"
dsc_script = "JoinADDomain.ps1"

cookbook_file "#{bootstrap_dir}\\#{dsc_script}.zip" do
   source "#{dsc_script}.zip"
   action :create
end

directory mod_dir do
end

powershell_script "unzip-#{dsc_script}" do
    code "#{bootstrap_dir}\\unzip.ps1 #{bootstrap_dir}\\#{dsc_script}.zip #{mod_dir}"
    creates "#{mod_dir}\\#{dsc_script}"
end

template "#{bootstrap_dir}\\reset-ad-trust-relationship.ps1" do
  source "reset-ad-trust-relationship.ps1.erb"
end


[
    'PSDesiredStateConfiguration'
].each do |feature|
    powershell_script "Install #{feature}" do
        code "Install-Module -Name #{feature} -Force"
        only_if "!(Get-Module #{feature} -ListAvailable)"
        not_if '(Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain'
    end
end

powershell_script 'set-dsc-JoinADDomain' do
    code <<-EOH
    $Acl = Get-Acl "#{modules_dir}"
    Set-Acl "#{mod_dir}" $Acl
    $oModPath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath + ";" + $pwd, "Machine")
    $env:PSModulePath = $env:PSModulePath + ";" + $pwd
    $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['ad']['admin']['password']}' -AsPlainText -Force
    $mycreds = New-Object System.Management.Automation.PSCredential ("#{node['hpcpack']['ad']['admin']['name']}", $secpasswd)

    $cd = @{
        AllNodes = @(
            @{
                NodeName = 'localhost'
                PSDscAllowPlainTextPassword = $true
                PSDscAllowDomainUser = $true
            }
        )}
    . .\\JoinADDomain.ps1
    JoinADDomain -DomainName "#{node['hpcpack']['ad']['domain']}" -DNSServer "#{node['hpcpack']['ad']['dns1']},8.8.8.8" -Admincreds $mycreds -RetryCount 4 -RetryIntervalSec 5 -ConfigurationData $cd
    Start-DscConfiguration .\\JoinADDomain -Wait -Force -Verbose
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath, "Machine")
    $env:PSModulePath = $oModPath
    EOH
    cwd mod_dir
    not_if '(Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain'
    notifies :run, 'ruby_block[set_reboot_required]', :immediately    
    # notifies :reboot_now, 'reboot[Restart Computer]', :immediately
end


# Allow users to uninstall specific windows updates (some apps haven't been ported to latest sec. updates)
# - Most updates require a reboot,
#   and domain join may fail if we uninstall before the join, so uninstall after join
#   but try hard to do all of this in one reboot
if not node['hpcpack']['uninstall_updates'].nil?
  
  node['hpcpack']['uninstall_updates'].each do |kb|
    kb_number = kb.downcase
    kb_number.slice!('kb')
    powershell_script "uninstall windows update: #{kb}" do
      code <<-EOH
      wusa.exe /uninstall /kb:#{kb_number} /norestart /quiet
      EOH
      only_if "dism.exe /online /get-packages | findstr /I #{kb}"
      notifies :run, 'ruby_block[set_reboot_required]', :immediately    
    end
  end

end

# Notify the reboot resource after loop
ruby_block "reboot_after_updates" do
  block do
    if not node['hpcpack']['uninstall_updates'].nil?
      Chef::Log.warn("Rebooting after joining domain and uninstalling #{node['hpcpack']['uninstall_updates'].inspect}...")
    else
      Chef::Log.warn("Rebooting after joining domain...")
    end
  end
  action :run
  only_if { reboot_required == true }
  notifies :reboot_now, 'reboot[Restart Computer]', :immediately
end

# To be safe - reset trust connection on each converge
powershell_script 'reset-ad-trust-relationship' do
    code "#{bootstrap_dir}\\reset-ad-trust-relationship.ps1"
end

