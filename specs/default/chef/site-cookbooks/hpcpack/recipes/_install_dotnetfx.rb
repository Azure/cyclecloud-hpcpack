# HPC Pack 2016 requires NetFx 4.6, HPC Pack 2019 requires NetFx 4.7.2
# The Windows Server 2012 R2/2016/2019 images in Azure Marketplace are all with 4.7.2 pre-installed
# In case NetFx not installed, we will try to copy from head node and install
powershell_script 'Copy-DotNetFx' do
  code  <<-EOH
  $reminst = "\\\\#{node['hpcpack']['hn']['hostname']}\\REMINST"
  $retry = 0
  While($true) {
    if(Test-Path "$reminst\\DotNetFramework") {
      Copy-Item -Path "$reminst\\DotNetFramework\\NDP*.exe" -Destination "#{node['jetpack']['downloads']}"
      break
    }
    elseif($retry++ -lt 50) {
      start-sleep -seconds 20
    }
    else {
      throw "head node not available"
    }
  }
  EOH
  not_if <<-EOH
    $targetNetFxVer = 461808
    $hpcVersion = "#{node['hpcpack']['version']}"
    if ($hpcVersion -eq '2016')
    {
      $targetNetFxVer = 393295
    }
    $netfxVer = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" -ErrorAction SilentlyContinue | Select -Property Release
    $netfxVer -and ($netfxVer.Release -ge $targetNetFxVer)
  EOH
end

powershell_script 'install-dotnetfx' do
  code <<-EOH
    $ndpLogFile = "C:\\cycle\\jetpack\\logs\\ndpinstall.log"
    $file = Get-Item "#{node['jetpack']['downloads']}\\NDP*.exe" | select -First(1)
    $filePath = $file.FullName
    if($file.Name -match "-web.exe$") {
      Start-Process -FilePath $filePath -ArgumentList "/q /norestart /serialdownload /log `"$ndpLogFile`"" -Wait -PassThru
    }
    else {
      Start-Process -FilePath $filePath -ArgumentList "/q /norestart /log `"$ndpLogFile`"" -Wait -PassThru
    }
  EOH
  not_if <<-EOH
    $targetNetFxVer = 461808
    $hpcVersion = "#{node['hpcpack']['version']}"
    if ($hpcVersion -eq '2016')
    {
      $targetNetFxVer = 393295
    }
    $netfxVer = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" -ErrorAction SilentlyContinue | Select -Property Release
    $netfxVer -and ($netfxVer.Release -ge $targetNetFxVer)
  EOH
  notifies :reboot_now, 'reboot[Restart Computer]', :immediately
end    
