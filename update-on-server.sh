#!/bin/bash

set -ex

host=${CC_HOST:?'must be specified!'}
user=${CC_USER:?'must be specified!'}
version=${CC_HPCPACK_VERSION:?'must be specified!'}

local_src=build/hpcpack
source_dir=/home/$user/hpcpack

# NOTE: The install_dir must match the real path on server.
install_dir=/opt/cycle_server/work/staging/projects/hpcpack/$version

# NOTE: The trailing '/' matters to rsync!
rsync -rtvi --del $local_src/ $user@$host:$source_dir/

ssh $user@$host /bin/bash << EOF
  set -ex

  echo \$(date) on \$(hostname)

  if [[ ! -d "$source_dir" ]]; then
    echo "'$source_dir' doesn't exist!"
    exit 1
  fi

  if ! sudo ls "$install_dir" > /dev/null; then
    echo "'$install_dir' doesn't exist!"
    exit 1
  fi

  sudo rsync -rtvi --del $source_dir/ $install_dir/
  sudo chown -R cycle_server:cycle_server $install_dir

  sudo tree -F $(dirname $install_dir)
  sudo ls -lFR $(dirname $install_dir)
EOF

echo "Done!"