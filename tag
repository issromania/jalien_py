#!/usr/bin/env bash

[[ ! -e alienpy/alien.py ]] && { echo "alien.py was not found"; exit 1; }

VER=$(python3 -c 'from alienpy.version import *;print(ALIENPY_VERSION_STR)') # '
[[ -z ${VER} ]] && { echo "Something is wrong, could not get the version number"; exit 1; }

# check the tag before the version commit and the push; exact match (1.7.1 is not 1.7.10)
tag_list="$(git --no-pager tag --sort=committerdate)"
echo "${tag_list}" | grep -qxF "${VER}" && { echo "tag ${VER} already done"; exit 1; }

./update_version
git commit -m "alien.py update version info" alienpy/*.py
git push
git push xjalienfs master

git tag ${VER}
git push --tags
git push --tags xjalienfs master

#tag=$(git describe --tags --abbrev=0 --exact-match)

