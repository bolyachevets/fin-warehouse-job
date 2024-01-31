#!/bin/bash
root_dir="/opt/app-root"
cd $root_dir
truncate_file="truncate_table.sql"

if [ "$TEST_DATA_LOAD_MODE" == true ]; then
  export LOAD_PAY="true"
  # export LOAD_AUTH="true"
  export LOAD_COLIN_DELTAS="true"
  export LOAD_CAS_DELTAS="true"
  export UPDATE_READONLY_ACCESS="true"
  export CREATE_VIEWS="true"
fi

if [ "$PROD_DATA_LOAD_MODE" == true ]; then
  export LOAD_PAY="true"
  # export LOAD_AUTH="true"
  export LOAD_CACHED_COLIN_DELTAS="true"
  export LOAD_CACHED_CAS_DELTAS="true"
  export UPDATE_READONLY_ACCESS="true"
  export CREATE_VIEWS="true"
fi

if [ "$LOAD_PAY" == true ] || [ "$LOAD_COLIN_DELTAS" == true ] || [ "$LOAD_COLIN_BASE" == true ] || [ "$LOAD_CAS_DELTAS" == true ] || [ "$MOVE_BASE_FILES_TO_OCP" == true ]; then
  echo "connecting to openshift"
  oc login --server=$OC_SERVER --token=$OC_PAY_TOKEN
fi

load_oc_db() {
  local namespace="$1"
  local db="$2"
  local schema="$3"
  pod_name=$(oc -n $namespace get pods --selector=$OC_LABEL -o name)
  prefix="pod/"
  pod_name=${pod_name#"$prefix"}
  date=$(TZ=US/Pacific date +%Y-%m-%d)
  src="${pod_name}://backups/daily/${date}/postgresql-${OC_ENV}-${db}_${date}_01-00-00.sql.gz"
  db_file="${db}.sql.gz"
  oc -n $namespace cp $src $db_file
  if [ -e $db_file ]
  then
      echo "downloaded successfully from daily backups"
  else
    src="${pod_name}://backups/monthly/${date}/postgresql-${OC_ENV}-${db}_${date}_01-00-00.sql.gz"
    oc -n $namespace cp $src $db_file
    echo "downloaded successfully from monthly backups"
  fi
  gunzip $db_file
  db_file2="${db}.sql"
  sed -i -e "6s/^//p; 6s/^.*/DROP SCHEMA IF EXISTS postgres_exporter CASCADE;/" $db_file2
  sed -i -e "6s/^//p; 6s/^.*/DROP SCHEMA IF EXISTS ${schema} CASCADE;/" $db_file2
  sed -i -e "7s/^//p; 7s/^.*/ALTER SCHEMA public RENAME to public_save;/" $db_file2
  sed -i -e "8s/^//p; 8s/^.*/CREATE SCHEMA public;/" $db_file2
  sed -i -e "9s/^//p; 9s/^.*/GRANT ALL ON SCHEMA public TO postgres;/" $db_file2
  sed -i -e "10s/^//p; 10s/^.*/GRANT ALL ON SCHEMA public TO public;/" $db_file2
  echo "ALTER SCHEMA public RENAME to ${schema};" >> $db_file2
  echo "ALTER SCHEMA public_save RENAME to public;" >> $db_file2
  gzip $db_file2
  gsutil cp $db_file "gs://${DB_BUCKET}/${db}/"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/${db_file}" --database=$DB_NAME --user=$DB_USER
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
}

pull_file_from_ocp () {
  echo "connecting to openshift"
  oc login --server=$OC_SERVER --token=$OC_PAY_TOKEN
  local filename="$1"
  local file_dir="$2"
  local schema="$3"
  pod_name="pvc-connector"
  oc -n $OC_PAY_NAMESPACE create -f "${pod_name}-pod.yaml"
  oc -n $OC_PAY_NAMESPACE wait --for=condition=ready pod $pod_name
  src="${pod_name}://${file_dir}"
  echo "copying file from openshift ..."
  oc -n $OC_PAY_NAMESPACE cp "${src}/${filename}" "./${filename}"
  oc -n $OC_PAY_NAMESPACE delete pod $pod_name
  sed -i -e "2s/^//p; 2s/^.*/SET search_path TO ${schema};/" "./${filename}"
  gsutil cp "./${filename}" "gs://${DB_BUCKET}/cprd/"
  truncate_file $filename $schema
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/cprd/${filename}" --database=$DB_NAME --async
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
}

truncate_table () {
  local filename="$1"
  local schema="$2"
  touch $truncate_file
  file_suffix2="_output.sql"
  tablename="${filename%"$file_suffix2"}"
  if [[ $tablename = *[0-9] ]]; then
   tablename=$(echo $tablename | sed 's/_[^_]*$//g')
  fi
  tablename_lower=$(echo $tablename | tr '[:upper:]' '[:lower:]')
  echo "TRUNCATE TABLE ${schema}.${tablename_lower};" >> $truncate_file
  gsutil cp $truncate_file "gs://${DB_BUCKET}/"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${truncate_file}" --database=$DB_NAME --user=$DB_USER
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
}

pull_file_from_cache () {
  local filename="$1"
  local schema="$2"
  local folder="$3"
  local truncate="$4"
  if [ "$truncate" == "true" ]; then
    truncate_table $filename $schema
  fi
  load_file $filename $folder
}

load_file () {
  local filename="$1"
  local folder="$2"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${folder}/${filename}" --database=$DB_NAME --async
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
}

if [ "$MOVE_BASE_FILES_TO_OCP" == true ]; then
  file_dir="data-yesterday"
  pod_name="pvc-connector"
  oc -n $OC_PAY_NAMESPACE create -f "${pod_name}-pod.yaml"
  oc -n $OC_PAY_NAMESPACE wait --for=condition=ready pod $pod_name
  src="${pod_name}://${file_dir}"
  file_suffix="_output.sql"
  for filename in $(gcloud storage ls "gs://${DB_BUCKET}/cprd"); do
    if [[ $filename == *"$file_suffix" ]]; then
      echo "$filename"
      gsutil cp $filename .
      basename=$(basename ${filename})
      oc -n $OC_PAY_NAMESPACE cp "./${basename}" "${pod_name}://data-yesterday/${basename}"
    fi
  done
  oc -n $OC_PAY_NAMESPACE delete pod $pod_name
fi

if [ ! -z "$PULL_CACHED_BASE_FILE_COLIN_TRUNCATE" ]; then
  pull_file_from_cache $PULL_CACHED_BASE_FILE_COLIN_TRUNCATE "COLIN" "cprd" "true"
fi

if [ ! -z "$PULL_CACHED_BASE_FILE_COLIN" ]; then
  pull_file_from_cache $PULL_CACHED_BASE_FILE_COLIN "COLIN" "cprd" "false"
fi

if [ ! -z "$PULL_CACHED_DELTA_FILE_COLIN" ]; then
  pull_file_from_cache $PULL_CACHED_DELTA_FILE_COLIN "COLIN" "cprd-delta" "false"
fi

if [ ! -z "$PULL_CACHED_BASE_FILE_CAS_TRUNCATE" ]; then
  pull_file_from_cache $PULL_CACHED_BASE_FILE_CAS_TRUNCATE "CAS" "cas/annual" "true"
fi

if [ ! -z "$PULL_CACHED_BASE_FILE_CAS" ]; then
  pull_file_from_cache $PULL_CACHED_BASE_FILE_CAS "CAS" "cas/annual" "false"
fi

if [ ! -z "$PULL_CACHED_DELTA_FILE_CAS" ]; then
  pull_file_from_cache $PULL_CACHED_DELTA_FILE_CAS "CAS" "cas/upsert" "false"
fi

if [ ! -z "$PULL_BASE_FILE_FROM_OCP_COLIN" ]; then
  pull_file_from_ocp $PULL_BASE_FILE_FROM_OCP_COLIN "data-yesterday" "COLIN"
fi

if [ "$LOAD_PAY" == true ]; then
  echo "loading pay-db dump ..."
  load_oc_db $OC_PAY_NAMESPACE "pay-db" "PAY"
fi

if [ "$LOAD_AUTH" == true ]; then
  echo "connecting to openshift"
  oc login --server=$OC_SERVER --token=$OC_AUTH_TOKEN
  echo "loading auth-db dump ..."
  load_oc_db $OC_AUTH_NAMESPACE "auth-db" "AUTH"
fi

if [ "$LOAD_COLIN_SCHEMA" == true ]; then
  echo "dropping cprd schema ..."
  touch drop_colin_schema.sql
  echo "DROP SCHEMA colin CASCADE;" >> drop_colin_schema.sql
  gsutil cp drop_colin_schema.sql "gs://${DB_BUCKET}/"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/drop_colin_schema.sql" --database=$DB_NAME --user=$DB_USER
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
  echo "loading cprd schema ..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/colin.sql" --database=$DB_NAME
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
  echo "load indexes ..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/views/view_indexes.sql" --database=$DB_NAME
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
fi

if [ "$LOAD_CAS_SCHEMA" == true ]; then
  echo "dropping cas schema ..."
  touch drop_cas_schema.sql
  echo "DROP SCHEMA cas CASCADE;" >> drop_cas_schema.sql
  gsutil cp drop_cas_schema.sql "gs://${DB_BUCKET}/"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/drop_cas_schema.sql" --database=$DB_NAME --user=$DB_USER
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
  echo "loading cas schema ..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/cas.sql" --database=$DB_NAME
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
  echo "load indexes ..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/views/view_indexes.sql" --database=$DB_NAME
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
fi

if [ "$LOAD_CACHED_COLIN_BASE" == true ]; then
  echo "loading colin base files ..."
  schema="COLIN"
  file_suffix="_output.sql"
  for filename in $(gcloud storage ls "gs://${DB_BUCKET}/cprd"); do
    if [[ $filename == *"$file_suffix" ]]; then
      echo "$filename"
      gcloud --quiet sql import sql $GCP_SQL_INSTANCE $filename --database=$DB_NAME --async
      gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
    fi
  done
fi

if [ "$LOAD_COLIN_BASE" == true ]; then
  echo "copying cprd base files from openshift ..."
  file_dir="data-yesterday"
  pod_name="pvc-connector"
  oc -n $OC_PAY_NAMESPACE create -f "${pod_name}-pod.yaml"
  oc -n $OC_PAY_NAMESPACE wait --for=condition=ready pod $pod_name
  src="${pod_name}://${file_dir}"
  mkdir $file_dir
  oc -n $OC_PAY_NAMESPACE rsync "${src}/" "./${file_dir}"
  sleep 60
  oc -n $OC_PAY_NAMESPACE delete pod $pod_name
  echo "loading cprd base files into gcp..."
  file_suffix="_output.sql"
  schema="COLIN"
  for filename in $(ls "./${file_dir}"); do
    echo $filename
    if [[ $filename == *"$file_suffix" ]]; then
      sed -i -e "2s/^//p; 2s/^.*/SET search_path TO ${schema};/" "./${file_dir}/$filename"
      gsutil cp "./${file_dir}/$filename" "gs://${DB_BUCKET}/cprd/"
      rm "./${file_dir}/$filename"
      gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/cprd/${filename}" --database=$DB_NAME --async
      gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
    fi
  done
fi

if [ "$LOAD_CACHED_COLIN_DELTAS" == true ]; then
  echo "loading cached cprd delta files ..."
  schema="COLIN"
  file_suffix="_delta.sql"
  for filename in $(gcloud storage ls "gs://${DB_BUCKET}/cprd-delta"); do
    if [[ $filename == *"$file_suffix" ]]; then
      echo "$filename"
      gcloud --quiet sql import sql $GCP_SQL_INSTANCE $filename --database=$DB_NAME --async
      gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
    fi
  done
fi

if [ "$LOAD_COLIN_DELTAS" == true ]; then
  echo "copying cprd deltas ..."
  file_dir="data"
  pod_name="pvc-connector"
  oc -n $OC_PAY_NAMESPACE create -f "${pod_name}-pod.yaml"
  oc -n $OC_PAY_NAMESPACE wait --for=condition=ready pod $pod_name
  src="${pod_name}://${file_dir}"
  mkdir $file_dir
  oc -n $OC_PAY_NAMESPACE rsync "${src}/" "./${file_dir}"
  sleep 30
  #oc -n $OC_PAY_NAMESPACE exec ${pod_name} -- rm -rf "${file_dir}"
  oc -n $OC_PAY_NAMESPACE delete pod $pod_name
  echo "loading colin deltas ..."
  file_suffix="_delta.sql"
  schema="COLIN"
  for filename in $(ls "./${file_dir}"); do
    echo $filename
    if [[ $filename == *"$file_suffix" ]]; then
      filesize=$(wc -c <"./${file_dir}/$filename")
      echo "file size:"
      echo $filesize
      if [ $filesize -ge $MAX_DELTA_SIZE ]; then
        rm "./${file_dir}/$filename"
        tablename="${filename%"$file_suffix"}"
        tablename_upper=$(echo $tablename | tr '[:lower:]' '[:upper:]')
        base_filename="${tablename_upper}_output.sql"
        echo "file too large - skipping delta, loading base file instead..."
        echo $base_filename
        pull_file_from_ocp $base_filename "data-yesterday" $schema
        # Delete delta stored as we will not be using it
        gcloud storage rm "gs://${DB_BUCKET}/cprd-delta/${filename}"
      else
        echo "processing delta..."
        sed -i -e "2s/^//p; 2s/^.*/SET search_path TO ${schema};/" "./${file_dir}/$filename"
        gsutil cp "./${file_dir}/$filename" "gs://${DB_BUCKET}/cprd-delta/"
        rm "./${file_dir}/$filename"
        gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/cprd-delta/${filename}" --database=$DB_NAME --async
        gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
      fi
    fi
  done
fi

# DEPRECATED
if [ "$LOAD_CAS" == true ]; then
  echo "loading cas base files ..."
  file_suffix="_output.sql"
  for filename in $(gcloud storage ls "gs://${DB_BUCKET}/cas"); do
    if [[ $filename == *"$file_suffix" ]]; then
      echo "$filename"
      gcloud --quiet sql import sql $GCP_SQL_INSTANCE $filename --database=$DB_NAME --async
      gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
    fi
  done
fi

if [ "$LOAD_CAS_DELTAS" == true ]; then
  echo "copying cas deltas ..."
  file_dir="data-cas/update"
  pod_name="pvc-connector"
  oc -n $OC_PAY_NAMESPACE create -f "${pod_name}-pod.yaml"
  oc -n $OC_PAY_NAMESPACE wait --for=condition=ready pod $pod_name
  src="${pod_name}://${file_dir}"
  mkdir -p $file_dir
  oc -n $OC_PAY_NAMESPACE rsync "${src}/" "./${file_dir}"
  sleep 30
  # oc -n $OC_PAY_NAMESPACE exec ${pod_name} -- rm -rf "${file_dir}"
  oc -n $OC_PAY_NAMESPACE delete pod $pod_name
  echo "loading cas deltas ..."
  file_suffix="_output.sql"
  schema="CAS"
  for filename in $(ls "./${file_dir}"); do
    echo $filename
    if [[ $filename == *"$file_suffix" ]]; then
        echo "processing delta..."
        gsutil cp "./${file_dir}/$filename" "gs://${DB_BUCKET}/cas/upsert/"
        rm "./${file_dir}/$filename"
        load_file $filename "cas/upsert"
    fi
  done
fi

if [ "$LOAD_CACHED_CAS_DELTAS" == true ]; then
  echo "loading cached cas delta files ..."
  schema="COLIN"
  file_suffix="_output.sql"
  for filename in $(gcloud storage ls "gs://${DB_BUCKET}/cas/upsert"); do
    if [[ $filename == *"$file_suffix" ]]; then
      echo "$filename"
      gcloud --quiet sql import sql $GCP_SQL_INSTANCE $filename --database=$DB_NAME --async
      gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
    fi
  done
fi

if [ "$CREATE_VIEWS" == true ]; then
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/views/views.sql" --database=$DB_NAME --user=$DB_USER
fi

touch readonly.sql

if [ "$CREATE_READONLY_USER" == true ]; then
  echo "writing create readonly user directives ..."
  # gcloud sql users set-password $DB_USER --instance=$GCP_SQL_INSTANCE --password=$DB_PASSWORD
  echo "CREATE USER readonly WITH PASSWORD ${DB_PASSWORD};" >> readonly.sql
  echo "GRANT CONNECT ON DATABASE ${DB_NAME} to readonly;" >> readonly.sql
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
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
fi
