#!/usr/bin/env bash

mkdir -p ${WORKSPACE_TMP}

[[ -e create_chroot.sh ]] && ./create_chroot.sh bullseye || exit 1

tar --exclude="./.*" -zcf ${WORKSPACE_TMP}/${BUILD_TAG}.tar.gz -C ${WORKSPACE} .

tag=$(git describe --abbrev=0 --tags )

id=$(curl -X 'POST' \
  'https://cloud:3001/api/v1/repos/marcel/bcrm/releases' \
  -H 'accept: application/json' \
  -H 'Authorization: token 8ed5c35cd994090c1105f8bd082c3ff94936aa84' \
  -H 'Content-Type: application/json' \
  -d '{
  "draft": false,
  "name": "${BUILD_TAG}",
  "prerelease": true,
  "tag_name": "$tag"
}')

curl -X 'POST' \
 "https://cloud:3001/api/v1/repos/marcel/bcrm/releases/$id/assets?name=x" \
 -H 'accept: application/json' \
 -H 'Authorization: token 8ed5c35cd994090c1105f8bd082c3ff94936aa84' \
 -H 'Content-Type: multipart/form-data' \
 -F "attachment=@${WORKSPACE_TMP}/${BUILD_TAG}.tar.gz"
