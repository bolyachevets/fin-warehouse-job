#!/bin/bash
root_dir="/opt/app-root"
cd $root_dir
gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/colin.sql" --database=$DB_NAME
file_suffix="_output.sql"
for filename in $(gcloud storage ls "gs://${DB_BUCKET}"); do
  if [[ $filename == *"$file_suffix" ]]; then
    echo "$filename"
    gcloud --quiet sql import sql $GCP_SQL_INSTANCE $filename --database=$DB_NAME --async
    gcloud sql operations list --instance='fin-warehouse-prod' --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
  fi
done
