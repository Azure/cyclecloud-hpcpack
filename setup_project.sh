#!/bin/bash

curl -k -L -O 'https://github.com/Azure/hpcpack-template-2016/archive/master.zip'
unzip master.zip
cp ./hpcpack-template-2016/shared-resources/* ./specs/default/chef/site-cookbooks/hpcpack/files/
rm -f master.zip




