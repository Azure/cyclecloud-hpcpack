#
# hpcpack::helpers.rb
#
require 'mixlib/shellout'
require "chef/mixin/powershell_out"
include Chef::Mixin::PowershellOut

module HPCPack
  class Helpers

    def self.powershell_out(script)
      
      result = powershell_out(script)
    end

    def self.keyvault_get_secret(vault_name, secret_key)
      # Cookbook path is sometimes a single string
      if Chef::Config[:cookbook_path].respond_to?('each')
        cookbook_path = Chef::Config[:cookbook_path][0]
      else
        cookbook_path = Chef::Config[:cookbook_path]
      end
      keyvault_get_secret_py = "#{cookbook_path}/../cookbooks/hpcpack/files/keyvault_get_secret.py"
      get_secret = Mixlib::ShellOut.new("python #{keyvault_get_secret_py} #{vault_name} #{secret_key}")
      get_secret.run_command

      # Throws an exception on error
      get_secret.error!
      
      secret_value = get_secret.stdout
      return secret_value
    end
    
  end
end
