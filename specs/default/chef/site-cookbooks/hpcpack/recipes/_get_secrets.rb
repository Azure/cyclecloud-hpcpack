bootstrap_dir = node['cyclecloud']['bootstrap']

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
Chef::Log.info( "Using AD Admin: #{node['hpcpack']['ad']['admin']['name']} and Pass:  #{node['hpcpack']['ad']['admin']['password']}..." )

