include_recipe "hpcpack::_get_secrets"

bootstrap_dir = node['cyclecloud']['bootstrap']

# Ensure that the local User is a local Admin
# This action will not be executed if the machine has been promoted as DC
group "add-Administrator" do
  action :nothing
  group_name "Administrators"
  members node['hpcpack']['ad']['admin']['name']
  append true
end

# Ensure that the local User has the same password as the AD User
# This action will not be executed if the machine has been promoted as DC
user "create-localuser" do
  username node['hpcpack']['ad']['admin']['name']
  password node['hpcpack']['ad']['admin']['password']
  action :nothing
  notifies :modify, 'group[add-Administrator]', :immediately
end

# Make sure create-localuser and add-Administrator will not be executed after promoting DC
# Because DC has no local user group
powershell_script 'create-LocalAdmin' do
  code <<-EOH
  hostname
  EOH
  not_if '(Get-WmiObject -Class Win32_ComputerSystem).DomainRole -eq 5'
  notifies :create, 'user[create-localuser]', :immediately
end

powershell_script 'promote-domain-controller' do
  code <<-EOH
  Import-Module ServerManager
  $adFeature = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction SilentlyContinue
  if($null -eq $adFeature -or !$adFeature.Installed)
  {
      Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
  }
  Import-Module ADDSDeployment
  $secpasswd = ConvertTo-SecureString "#{node['hpcpack']['ad']['admin']['password']}" -AsPlainText -Force
  Install-ADDSForest -DomainName "#{node['hpcpack']['ad']['domain']}" -InstallDNS -SafeModeAdministratorPassword $secpasswd -NoRebootOnCompletion -Force
  EOH
  not_if '(Get-WmiObject -Class Win32_ComputerSystem).DomainRole -eq 5'
  notifies :reboot_now, 'reboot[Restart Computer]', :immediately
end

powershell_script 'add-dns-forwarder' do
  code <<-EOH
  $IPAddresses = @('8.8.8.8')
  $setParams = @{
    Namespace = 'root\\MicrosoftDNS'
    Query = 'select * from microsoftdns_server'
    Property = @{Forwarders = $IPAddresses}
  }
  Set-CimInstance @setParams
  EOH
  not_if <<-EOH
  [array]$currentFwders = (Get-CimInstance -Namespace root\\MicrosoftDNS -ClassName microsoftdns_server).Forwarders
  $currentFwders -contains '8.8.8.8'
  EOH
end