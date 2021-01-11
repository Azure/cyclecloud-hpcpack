include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
bootstrap_dir = node['cyclecloud']['bootstrap']

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

cookbook_file "#{bootstrap_dir}\\joinADDomain.ps1" do
  source "joinADDomain.ps1"
  action :create
end

# Ensure that the local User is a local Admin 
group "LocalAdmin" do
  action :modify
  group_name 'Administrators'
  members node['hpcpack']['ad']['admin']['name']
  append true
end

powershell_script 'join-ADDomain' do
  code <<-EOH
  $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['ad']['admin']['password']}' -AsPlainText -Force
  $domainCred = New-Object System.Management.Automation.PSCredential ("#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}", $secpasswd)
  #{bootstrap_dir}\\joinADDomain.ps1 -DomainName #{node['hpcpack']['ad']['domain']} -DnsServers @("#{node['hpcpack']['ad']['dns1']}") -Credential $domainCred -LogFilePath "#{bootstrap_dir}\\joinADDomain.txt"
  EOH
  not_if '(Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain'
  notifies :run, 'ruby_block[set_reboot_required]', :immediately    
end

# Notify the reboot resource after loop
ruby_block "reboot_after_join_domain" do
  block do
    Chef::Log.warn("Rebooting after joining domain...")
  end
  action :run
  only_if { reboot_required == true }
  notifies :reboot_now, 'reboot[Restart Computer]', :immediately
end

group "Administrators" do
  action :modify
  members "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
  append true
end

# To be safe - reset trust connection on each converge
#powershell_script 'reset-ad-trust-relationship' do
#  code "#{bootstrap_dir}\\reset-ad-trust-relationship.ps1"
#end

