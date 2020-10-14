#!/bin/bash

curl -k -L -O 'https://github.com/Azure/hpcpack-template-2016/archive/master.zip'
unzip master.zip
cp ./hpcpack-template-2016/shared-resources/* ./specs/default/chef/site-cookbooks/hpcpack/files/
rm -f master.zip


curl -k -L -O 'https://github.com/chef-cookbooks/windows/archive/v4.2.2.zip'
unzip v4.2.2.zip
mv windows-4.2.2 ./specs/default/chef/site-cookbooks/windows
rm -f v4.2.2.zip

curl -k -L -o 'ndp48-web.exe' 'http://go.microsoft.com/fwlink/?LinkId=2085155'
cp 'ndp48-web.exe' ./blobs/


curl -k -L -o nuget.exe 'https://aka.ms/nugetclidl'
cp 'nuget.exe' ./blobs/


