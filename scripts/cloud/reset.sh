#!/bin/bash
#
# Copyright 2018 Google Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Read command line arguments.
while [ "$1" != "" ]; do
  case $1 in
    -h | --help )           echo "Usage: $0 cloud reset"
                            echo
                            break
  esac
  shift
done

# Get current project ID.
project_id_gae=`gcloud config get-value project 2>/dev/null`
stage="$SCRIPTS_DIR/variables/stages/${project_id_gae}.sh"

# Do we have stage description file?
if [ ! -f $stage ]; then
  echo "ERROR! Stage description file scripts/variables/stages/${project_id_gae}.sh not found!"
  exit 1
fi

# Install required packages.
echo
echo -e "$BLUE==>$NONE$BOLD Installing required packages$NONE"
echo
mkdir -p ~/.cloudshell
> ~/.cloudshell/no-apt-get-warning
sudo apt-get install -y rsync libmysqlclient-dev

# Load stage variables from stage description file.
echo
echo -e -n "$BLUE==>$NONE$BOLD Loading stage description file "
echo -e "scripts/variables/stages/${project_id_gae}.sh$NONE"
source "$stage"

# Display working directory.
echo
echo -e "$BLUE==>$NONE$BOLD Working directory: $workdir$NONE"

# Copy source code to the working directory.
if [ -x "$(command -v rsync)" ]; then
  rsync -r --exclude=.git --exclude=.idea --exclude='*.pyc' \
    --exclude=frontend/node_modules --exclude=backends/data/*.json . $workdir
fi

# Copy service account file for deployment.
# cp backends/data/$service_account_file $workdir/backends/data/service-account.json

# Make app_data.json for backends.
# cat > $workdir/backends/data/app.json <<EOL
# {
  # "notification_sender_email": "$notification_sender_email",
  # "app_title": "$app_title"
# }
# EOL

# Copy service account file for deployment.
cp backends/data/$service_account_file $workdir/backends/data/service-account.json

# Make app_data.json for backends.
cat > $workdir/backends/data/app.json <<EOL
{
  "notification_sender_email": "$notification_sender_email",
  "app_title": "$app_title"
}
EOL

# Go to backends directory.
cd $workdir/backends

# Setting up virtual environment and installing Python libs.
virtualenv --python=python2 env
. env/bin/activate
mkdir -p lib
pip install -r ibackend/requirements.txt -t lib -q
pip install -r jbackend/requirements.txt -t lib -q

# Set DB connection variables.
cloudsql_dir=/tmp/cloudsql
local_db_uri="mysql+mysqldb://$db_username:$db_password@/$db_name?unix_socket=$cloudsql_dir/$db_instance_conn_name"

# Start Cloud SQL proxy
echo -e "$BLUE==>$NONE$BOLD Starting Cloud SQL proxy$NONE"
echo
mkdir -p $cloudsql_dir
$cloud_sql_proxy -projects=$project_id_gae -instances=$db_instance_conn_name -dir=$cloudsql_dir -credential_file=data/service-account.json &
cloud_sql_proxy_pid=$!
echo "cloud_sql_proxy pid: $cloud_sql_proxy_pid"
sleep 5  # Wait for cloud_sql_proxy to start.

# Variables required to run flask application.
export PYTHONPATH="$gcloud_sdk_dir/platform/google_appengine:lib"
export FLASK_APP=run_ibackend.py
export FLASK_DEBUG=1
export APPLICATION_ID=$project_id_gae

# Create DB config for local application fom migrations and seeds.
echo "SQLALCHEMY_DATABASE_URI=\"$local_db_uri\"" > $workdir/backends/instance/config.py

# Reset statuses of jobs and pipelines.
echo
echo -e "$BLUE==>$NONE$BOLD Reseting statuses of jobs and pipelines.$NONE"
echo
python -m flask reset_pipelines

# Stop Cloud SQL proxy.
echo
echo -e "$BLUE==>$NONE$BOLD Stopping Cloud SQL proxy$NONE"
echo
kill -s STOP $cloud_sql_proxy_pid
