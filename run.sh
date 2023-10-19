#!/bin/bash
root_dir="/opt/app-root"
cd $root_dir
oc login --server=$OC_SERVER --token=$OC_TOKEN
# pod_name=$(oc -n $OC_NAMESPACE get pods --selector=$OC_LABEL -o name)
# prefix="pod/"
# pod_name=${pod_name#"$prefix"}
# date=$(TZ=US/Pacific date +%Y-%m-%d)
# src="${pod_name}://backups/daily/${date}/postgresql-${OC_ENV}-pay-db_${date}_01-00-00.sql.gz"
# pay_db_file="pay-db.sql.gz"
# oc -n $OC_NAMESPACE cp $src $pay_db_file
# gunzip $pay_db_file
# pay_db_file2="pay-db.sql.gz.sql"
# sed -i -e "6s/^//p; 6s/^.*/DROP SCHEMA IF EXISTS postgres_exporter CASCADE;/" $pay_db_file2
# sed -i -e "6s/^//p; 6s/^.*/DROP SCHEMA IF EXISTS PAY CASCADE;/" $pay_db_file2
# sed -i -e "7s/^//p; 7s/^.*/ALTER SCHEMA public RENAME to public_save;/" $pay_db_file2
# sed -i -e "8s/^//p; 8s/^.*/CREATE SCHEMA public;/" $pay_db_file2
# sed -i -e "9s/^//p; 9s/^.*/GRANT ALL ON SCHEMA public TO postgres;/" $pay_db_file2
# sed -i -e "10s/^//p; 10s/^.*/GRANT ALL ON SCHEMA public TO public;/" $pay_db_file2
# echo "ALTER SCHEMA public RENAME to PAY;" >> $pay_db_file2
# echo "ALTER SCHEMA public_save RENAME to public;" >> $pay_db_file2
# gzip $pay_db_file2
# gsutil cp $pay_db_file "gs://a${DB_BUCKET}"
# gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${pay_db_file}" --database=$DB_NAME --user=$DB_USER
# pod_name="pvc-connector"
# oc -n $OC_NAMESPACE create -f "${pod_name}-pod.yaml"
# oc -n $OC_NAMESPACE wait --for=condition=ready pod $pod_name
# file_dir="data"
# src="${pod_name}://${file_dir}"
# oc -n $OC_NAMESPACE cp "${src}/" "./${file_dir}"
# oc -n $OC_NAMESPACE delete pod $pod_name
# # gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/colin.sql" --database=$DB_NAME
# file_suffix="_delta.sql"
# schema="COLINTEMP"
# for filename in $(ls "./${file_dir}"); do
#   echo $filename
#   if [[ $filename == *"$file_suffix" ]]; then
#     # file="$(basename "$filename")"
#     # gsutil cp "gs://${DB_BUCKET}/${file}" .
#     sed -i -e "2s/^//p; 2s/^.*/SET search_path TO ${schema};/" "./${file_dir}/$filename"
#     gsutil cp "./${file_dir}/$filename" "gs://${DB_BUCKET}"
#     rm "./${file_dir}/$filename"
#     gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${filename}" --database=$DB_NAME --async
#     gcloud sql operations list --instance='fin-warehouse-prod' --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
#   fi
# done

root_dir="/opt/app-root"
cd $root_dir
file_suffix="_output.sql"
for filename in $(gcloud storage ls "gs://${DB_BUCKET}/cas"); do
  if [[ $filename == *"$file_suffix" ]]; then
    echo "$filename"
    gcloud --quiet sql import sql $GCP_SQL_INSTANCE $filename --database=$DB_NAME --async
    gcloud sql operations list --instance='fin-warehouse-prod' --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
  fi
done


touch readonly.sql
# echo "CREATE USER readonly WITH PASSWORD ${DB_PASSWORD};" >> readonly.sql
# echo "GRANT CONNECT ON DATABASE fin_warehouse to readonly;" >> readonly.sql
# echo "GRANT USAGE ON SCHEMA colin TO readonly;" >> readonly.sql
# echo "GRANT SELECT ON ALL TABLES IN SCHEMA colin to readonly;" >> readonly.sql
# echo "ALTER DEFAULT PRIVILEGES IN SCHEMA colin GRANT SELECT ON TABLES TO readonly;" >> readonly.sql
# echo "GRANT USAGE ON SCHEMA pay TO readonly;" >> readonly.sql
# echo "GRANT SELECT ON ALL TABLES IN SCHEMA pay to readonly;" >> readonly.sql
# echo "ALTER DEFAULT PRIVILEGES IN SCHEMA pay GRANT SELECT ON TABLES TO readonly;" >> readonly.sql

echo "GRANT USAGE ON SCHEMA cas TO readonly;" >> readonly.sql
echo "GRANT SELECT ON ALL TABLES IN SCHEMA cas to readonly;" >> readonly.sql
echo "ALTER DEFAULT PRIVILEGES IN SCHEMA cas GRANT SELECT ON TABLES TO readonly;" >> readonly.sql

gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/readonly.sql" --database=$DB_NAME
gcloud sql users set-password $DB_USER --instance=$GCP_SQL_INSTANCE --password=$DB_PASSWORD
