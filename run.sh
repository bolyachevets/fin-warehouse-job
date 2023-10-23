#!/bin/bash
root_dir="/opt/app-root"
cd $root_dir

if [ "$LOAD_PAY" == true ] || [ "$LOAD_COLIN_DELTAS" == true ] || [ "$LOAD_CAS" == true ]; then
  echo "connecting to openshift"
  oc login --server=$OC_SERVER --token=$OC_TOKEN
fi

if [ "$LOAD_PAY" == true ]; then
  echo "loadig colin pay-db dump ..."
  pod_name=$(oc -n $OC_NAMESPACE get pods --selector=$OC_LABEL -o name)
  prefix="pod/"
  pod_name=${pod_name#"$prefix"}
  date=$(TZ=US/Pacific date +%Y-%m-%d)
  src="${pod_name}://backups/daily/${date}/postgresql-${OC_ENV}-pay-db_${date}_01-00-00.sql.gz"
  pay_db_file="pay-db.sql.gz"
  oc -n $OC_NAMESPACE cp $src $pay_db_file
  gunzip $pay_db_file
  pay_db_file2="pay-db.sql"
  sed -i -e "6s/^//p; 6s/^.*/DROP SCHEMA IF EXISTS postgres_exporter CASCADE;/" $pay_db_file2
  sed -i -e "6s/^//p; 6s/^.*/DROP SCHEMA IF EXISTS PAY CASCADE;/" $pay_db_file2
  sed -i -e "7s/^//p; 7s/^.*/ALTER SCHEMA public RENAME to public_save;/" $pay_db_file2
  sed -i -e "8s/^//p; 8s/^.*/CREATE SCHEMA public;/" $pay_db_file2
  sed -i -e "9s/^//p; 9s/^.*/GRANT ALL ON SCHEMA public TO postgres;/" $pay_db_file2
  sed -i -e "10s/^//p; 10s/^.*/GRANT ALL ON SCHEMA public TO public;/" $pay_db_file2
  echo "ALTER SCHEMA public RENAME to PAY;" >> $pay_db_file2
  echo "ALTER SCHEMA public_save RENAME to public;" >> $pay_db_file2
  gzip $pay_db_file2
  gsutil cp $pay_db_file "gs://${DB_BUCKET}/pay-db/"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/pay-db/${pay_db_file}" --database=$DB_NAME --user=$DB_USER
fi

if [ "$LOAD_COLIN_SCHEMA" == true ]; then
  echo "loadig colin schema ..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/colin.sql" --database=$DB_NAME
fi

if [ "$LOAD_CAS_SCHEMA" == true ]; then
  echo "loadig cas schema ..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/cas.sql" --database=$DB_NAME
fi

if [ "$LOAD_COLIN_DELTAS" == true ]; then
  echo "copying cronjob results ..."
  pod_name="pvc-connector"
  oc -n $OC_NAMESPACE create -f "${pod_name}-pod.yaml"
  oc -n $OC_NAMESPACE wait --for=condition=ready pod $pod_name
  file_dir="data"
  src="${pod_name}://${file_dir}"
  oc -n $OC_NAMESPACE cp "${src}/" "./${file_dir}"
  oc -n $OC_NAMESPACE delete pod $pod_name
fi


if [ "$LOAD_COLIN_DELTAS" == true ]; then
  echo "loadig colin deltas ..."
  file_suffix="_delta.sql"
  schema="COLIN"
  for filename in $(ls "./${file_dir}"); do
    echo $filename
    if [[ $filename == *"$file_suffix" ]]; then
      sed -i -e "2s/^//p; 2s/^.*/SET search_path TO ${schema};/" "./${file_dir}/$filename"
      gsutil cp "./${file_dir}/$filename" "gs://${DB_BUCKET}/colin/"
      rm "./${file_dir}/$filename"
      gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/colin/${filename}" --database=$DB_NAME --async
      gcloud sql operations list --instance='fin-warehouse-prod' --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
    fi
  done
fi

if [ "$LOAD_CAS" == true ]; then
  echo "loadig cas base files ..."
  # TODO - cas will be pulled from openshift VPC through the same pod as colin data above
  file_suffix="_output.sql"
  for filename in $(gcloud storage ls "gs://${DB_BUCKET}/cas"); do
    if [[ $filename == *"$file_suffix" ]]; then
      echo "$filename"
      gcloud --quiet sql import sql $GCP_SQL_INSTANCE $filename --database=$DB_NAME --async
      gcloud sql operations list --instance='fin-warehouse-prod' --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
    fi
  done
fi

touch readonly.sql

if [ "$CREATE_READONLY_USER" == true ]; then
  echo "writing create readonly user directives ..."
  # gcloud sql users set-password $DB_USER --instance=$GCP_SQL_INSTANCE --password=$DB_PASSWORD
  echo "CREATE USER readonly WITH PASSWORD ${DB_PASSWORD};" >> readonly.sql
  echo "GRANT CONNECT ON DATABASE fin_warehouse to readonly;" >> readonly.sql
fi


if [ "$UPDATE_READONLY_ACCESS" == true ]; then
  echo "writing grant readonly user directives ..."

  echo "GRANT USAGE ON SCHEMA pay TO readonly;" >> readonly.sql
  echo "GRANT SELECT ON ALL TABLES IN SCHEMA pay to readonly;" >> readonly.sql
  echo "ALTER DEFAULT PRIVILEGES IN SCHEMA pay GRANT SELECT ON TABLES TO readonly;" >> readonly.sql

  echo "GRANT USAGE ON SCHEMA colin TO readonly;" >> readonly.sql
  echo "GRANT SELECT ON ALL TABLES IN SCHEMA colin to readonly;" >> readonly.sql
  echo "ALTER DEFAULT PRIVILEGES IN SCHEMA colin GRANT SELECT ON TABLES TO readonly;" >> readonly.sql

  echo "GRANT USAGE ON SCHEMA cas TO readonly;" >> readonly.sql
  echo "GRANT SELECT ON ALL TABLES IN SCHEMA cas to readonly;" >> readonly.sql
  echo "ALTER DEFAULT PRIVILEGES IN SCHEMA cas GRANT SELECT ON TABLES TO readonly;" >> readonly.sql

fi

if [ "$CREATE_READONLY_USER" == true ] || [ "$UPDATE_READONLY_ACCESS" == true ]; then
  echo "applying readonly user changes ..."
  gsutil cp readonly.sql "gs://${DB_BUCKET}/"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/readonly.sql" --database=$DB_NAME --user=$DB_USER

fi
