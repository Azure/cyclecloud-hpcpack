bootstrap_dir = node['cyclecloud']['bootstrap']
config_dir = "#{node[:cyclecloud][:home]}\\config"

powershell_script 'Set-FileAccessPermissions' do
  code <<-EOH
  $acl = New-Object -TypeName System.Security.AccessControl.FileSecurity
  $acl.SetAccessRuleProtection($True, $False)
  foreach ($id in @("BUILTIN\\Administrators", "NT AUTHORITY\\SYSTEM")) {
      $aclRule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @($id, 'FullControl', 'Allow')
      $acl.AddAccessRule($aclRule)
  }
  $protectFiles = @("lockers.json", "connection.json", "node.json")
  foreach($file in $protectFiles)
  {
    try {    
      Set-Acl -Path "#{config_dir}\\$file" -AclObject $acl
    }
    catch { }
  }
  EOH
  not_if 'Test-Path -Path "#{bootstrap_dir}\\keyvault_get_secret.py"'
end

cookbook_file "#{bootstrap_dir}\\keyvault_get_secret.py" do
  source "keyvault_get_secret.py"
  action :create
end

# Lookup the AD Admin and Cert creds in KeyVault (if present)
if ! node['hpcpack']['keyvault']['vault_name'].nil?
  Chef::Log.info( "Looking up secrets in vault: #{node['hpcpack']['keyvault']['vault_name']}..." )


  if ! node['hpcpack']['keyvault']['admin']['name_key'].nil?

    
    admin_name = HPCPack::Helpers.keyvault_get_secret(node['hpcpack']['keyvault']['vault_name'], node['hpcpack']['keyvault']['admin']['name_key'])
    if admin_name.to_s.empty?
      raise "Error: AD Admin Username not set in #{node['hpcpack']['keyvault']['vault_name']} with key #{node['hpcpack']['keyvault']['admin']['name_key']}"
    end

    node.default['hpcpack']['ad']['admin']['name'] = admin_name
    node.override['hpcpack']['ad']['admin']['name'] = admin_name

  end
  
  if ! node['hpcpack']['keyvault']['admin']['password_key'].nil?
    admin_pass = HPCPack::Helpers.keyvault_get_secret(node['hpcpack']['keyvault']['vault_name'], node['hpcpack']['keyvault']['admin']['password_key'])
    if admin_pass.to_s.empty?
      raise "Error: AD Admin Password not set in #{node['hpcpack']['keyvault']['vault_name']} with key #{node['hpcpack']['keyvault']['admin']['password_key']}"
    end

    node.default['hpcpack']['ad']['admin']['password'] = admin_pass
    node.override['hpcpack']['ad']['admin']['password'] = admin_pass
    
  end
  
  if ! node['hpcpack']['keyvault']['cert']['password_key'].nil?
    cert_pass = HPCPack::Helpers.keyvault_get_secret(node['hpcpack']['keyvault']['vault_name'], node['hpcpack']['keyvault']['cert']['password_key'])
    if cert_pass.to_s.empty?
      raise "Error: AD Admin Password not set in #{node['hpcpack']['keyvault']['cert']['keyvault']} with key #{node['hpcpack']['keyvault']['cert']['password_key']}"
    end

    node.default['hpcpack']['cert']['password'] = cert_pass
    node.override['hpcpack']['cert']['password'] = cert_pass
    
  end
  
end
Chef::Log.info( "Using AD Admin: #{node['hpcpack']['ad']['admin']['name']} ..." )

