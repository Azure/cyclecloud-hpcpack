#
# Cookbook Name:: hpcpack
# Recipe:: _update_path
#

# Ensure that Jetpack python and openssl are on the PATH

def add_jetpack_paths(path_var)
  jetpack_paths = ['c:\\cycle\\jetpack\\system\\python', 
                   'c:\\cycle\\jetpack\\system\\embedded\\bin', 
                   'c:\\cycle\\jetpack\\system\\embedded\\python'].join(File::PATH_SEPARATOR)
  path_var += File::PATH_SEPARATOR + jetpack_paths
end

log "Original PATH: #{ENV['PATH']}" do
  level :info
end

# Clean the PATH
ENV['PATH'] = add_jetpack_paths(ENV['PATH'])

log "Expanded PATH: #{ENV['PATH']}" do
  level :info
end
