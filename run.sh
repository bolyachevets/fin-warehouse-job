#! /bin/sh
cd /opt/app-root
oc login --server=$OC_SERVER --token=$OC_TOKEN
pod_name=$(oc -n $OC_NAMESPACE get pods --selector='app=backup' -o name)
prefix="pod/"
pod_name=${pod_name#"$prefix"}
date=$(TZ=US/Pacific date +%Y-%m-%d)
src="${pod_name}://backups/daily/${date}/postgresql-${OC_ENV}-pay-db_${date}_01-00-00.sql.gz"
oc -n $OC_NAMESPACE cp $src .
src="./postgresql-dev-pay-db_${date}_01-00-00.sql.gz"
gsutil cp $src "gs://${DB_BUCKET}"
gcloud --quiet sql databases delete $DB_NAME --instance=$GCP_SQL_INSTANCE
gcloud sql databases create $DB_NAME --instance=$GCP_SQL_INSTANCE
gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/postgresql-${OC_ENV}-pay-db_${date}_01-00-00.sql.gz" --database=$DB_NAME --user=$DB_USER
gcloud sql users set-password $$DB_USER --instance=$GCP_SQL_INSTANCE --password=$DB_PASSWORD
