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
      keyvault_get_secret_py = "#{Chef::Config[:cookbook_path][0]}/../cookbooks/hpcpack/files/keyvault_get_secret.py"
      get_secret = Mixlib::ShellOut.new("python #{keyvault_get_secret_py} #{vault_name} #{secret_key}")
      get_secret.run_command

      # Throws an exception on error
      get_secret.error!
      
      secret_value = get_secret.stdout
      return secret_value
    end
    
  end
end
