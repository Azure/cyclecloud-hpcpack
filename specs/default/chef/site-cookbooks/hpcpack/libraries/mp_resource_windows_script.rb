require 'chef/resource/script'

class Chef
  class Resource
    class WindowsScript < Chef::Resource::Script
      set_guard_inherited_attributes(:password, :domain)
    end
  end
end
