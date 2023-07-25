#! /bin/sh
cd /opt/app-root
oc login --server=$OC_SERVER --token=$OC_TOKEN
pod_name=$(oc -n 78c88a-dev get pods --selector='app=backup' -o name)
prefix="pod/"
pod_name=${pod_name#"$prefix"}
date=$(date +%Y-%m-%d)
src="${pod_name}://backups/daily/${date}/postgresql-dev-pay-db_${date}_01-00-00.sql.gz"
oc cp $src .
ls -la
