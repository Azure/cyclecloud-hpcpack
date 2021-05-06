#!/bin/bash 
set -x
DIR="$( cd "$( dirname "$( readlink "${BASH_SOURCE[0]}" )" )" && pwd )"

rm -rf ./.venv_cchpcpack_build
python3 -m venv ~/.venv_cchpcpack_build
. ~/.venv_cchpcpack_build/bin/activate
pip install -U pip

pushd ${DIR}
rm -f blobs/cyclecloud-hpcpack-pkg-*.zip
rm -f ./dist/* ./libs/*

# Ensure that subprocess picks the correct pip
export PATH=~/.venv_cchpcpack_build/bin:$PATH
python3 ./package.py
cp ./dist/cyclecloud-hpcpack-pkg-*.zip ./blobs/
popd


# Install uses nuget to install python3 on windows if not already installed
# TODO: This won't work in locked down environments where nuget is blocked
# curl -k -L -o nuget.exe 'https://aka.ms/nugetclidl'
# mv 'nuget.exe' ./blobs/


