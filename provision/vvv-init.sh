#!/usr/bin/env bash
# Provision WordPress Stable

set -eo pipefail

echo " * Custom site template provisioner ${VVV_SITE_NAME} - downloads and installs a copy of WP stable for testing, building client sites, etc"

# fetch the first host as the primary domain. If none is available, generate a default using the site name
DOMAIN=$(get_primary_host "${VVV_SITE_NAME}".test)
SITE_TITLE=$(get_config_value 'site_title' "${DOMAIN}")
WP_VERSION=$(get_config_value 'wp_version' 'latest')
WP_LOCALE=$(get_config_value 'locale' 'en_US')
WP_TYPE=$(get_config_value 'wp_type' "single")
DB_NAME=$(get_config_value 'db_name' "${VVV_SITE_NAME}")
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*]/}
DB_PREFIX=$(get_config_value 'db_prefix' 'wp_')

# Make a database, if we don't already have one
setup_database() {
  echo -e " * Creating database '${DB_NAME}' (if it's not already there)"
  mysql -u root --password=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`"
  echo -e " * Granting the wp user priviledges to the '${DB_NAME}' database"
  mysql -u root --password=root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO wp@localhost IDENTIFIED BY 'wp';"
  echo -e " * DB operations done."
}

setup_nginx_folders() {
  echo " * Setting up the log subfolder for Nginx logs"
  noroot mkdir -p "${VVV_PATH_TO_SITE}/log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-error.log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-access.log"
  echo " * Creating public_html folder if it doesn't exist already"
  noroot mkdir -p "${VVV_PATH_TO_SITE}/public_html"
}

install_plugins() {
  WP_PLUGINS=$(get_config_value 'install_plugins' '')
  if [ ! -z "${WP_PLUGINS}" ]; then
    for plugin in ${WP_PLUGINS//- /$'\n'}; do
        echo " * Installing/activating plugin: '${plugin}'"
        noroot wp plugin install "${plugin}" --activate
    done
  fi
}

install_themes() {
  WP_THEMES=$(get_config_value 'install_themes' '')
  if [ ! -z "${WP_THEMES}" ]; then
      for theme in ${WP_THEMES//- /$'\n'}; do
        echo " * Installing theme: '${theme}'"
        noroot wp theme install "${theme}"
      done
  fi
}

copy_nginx_configs() {
  echo " * Copying the sites Nginx config template"
  if [ -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" ]; then
    echo " * A vvv-nginx-custom.conf file was found"
    cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    echo " * Using the default vvv-nginx-default.conf, to customize, create a vvv-nginx-custom.conf"
    cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-default.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi

  LIVE_URL=$(get_config_value 'live_url' '')
  if [ ! -z "$LIVE_URL" ]; then
    echo " * Adding support for Live URL redirects to NGINX of the website's media"
    # replace potential protocols, and remove trailing slashes
    LIVE_URL=$(echo "${LIVE_URL}" | sed 's|https://||' | sed 's|http://||'  | sed 's:/*$::')

    redirect_config=$((cat <<END_HEREDOC
if (!-e \$request_filename) {
  rewrite ^/[_0-9a-zA-Z-]+(/wp-content/uploads/.*) \$1;
}
if (!-e \$request_filename) {
  rewrite ^/wp-content/uploads/(.*)\$ \$scheme://${LIVE_URL}/wp-content/uploads/\$1 redirect;
}
END_HEREDOC

    ) |
    # pipe and escape new lines of the HEREDOC for usage in sed
    sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n\\1/g'
    )

    sed -i -e "s|\(.*\){{LIVE_URL}}|\1${redirect_config}|" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    sed -i "s#{{LIVE_URL}}##" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi
}

setup_wp_config_constants() {
  set +e
  shyaml get-values-0 -q "sites.${VVV_SITE_NAME}.custom.wpconfig_constants" < "${VVV_CONFIG}" |
  while IFS='' read -r -d '' key &&
        IFS='' read -r -d '' value; do
      lower_value=$(echo "${value}" | awk '{print tolower($0)}')
      echo " * Adding constant '${key}' with value '${value}' to wp-config.php"
      if [ "${lower_value}" == "true" ] || [ "${lower_value}" == "false" ] || [[ "${lower_value}" =~ ^[+-]?[0-9]*$ ]] || [[ "${lower_value}" =~ ^[+-]?[0-9]+\.?[0-9]*$ ]]; then
        noroot wp config set "${key}" "${value}" --raw
      else
        noroot wp config set "${key}" "${value}"
      fi
  done
  set -e
}

restore_db_backup() {
  echo " * Found a database backup at ${1}. Restoring the site"
  noroot wp config set DB_USER "wp"
  noroot wp config set DB_PASSWORD "wp"
  noroot wp config set DB_HOST "localhost"
  noroot wp config set DB_NAME "${DB_NAME}"
  noroot wp config set table_prefix "${DB_PREFIX}"
  noroot wp db import "${1}"
  echo " * Installed database backup"
}

download_wordpress() {
  # Install and configure the latest stable version of WordPress
  echo " * Downloading WordPress version '${2}' locale: '${3}'"
  noroot wp core download --locale="${3}" --version="${2}" --path="${1}"
}

initial_wpconfig() {
  echo " * Setting up wp-config.php"
  noroot wp core config --dbname="${DB_NAME}" --dbprefix="${DB_PREFIX}" --dbuser=wp --dbpass=wp  --extra-php <<PHP
define( 'WP_DEBUG', true );
define( 'SCRIPT_DEBUG', true );
PHP
}

install_wp() {
  echo " * Installing WordPress"
  ADMIN_USER=$(get_config_value 'admin_user' "admin")
  ADMIN_PASSWORD=$(get_config_value 'admin_password' "password")
  ADMIN_EMAIL=$(get_config_value 'admin_email' "admin@local.test")

  echo " * Installing using wp core install --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\" --path=\"${VVV_PATH_TO_SITE}/public_html\""
  noroot wp core install --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
  echo " * WordPress was installed, with the username '${ADMIN_USER}', and the password '${ADMIN_PASSWORD}' at '${ADMIN_EMAIL}'"

  if [ "${WP_TYPE}" = "subdomain" ]; then
    echo " * Running Multisite install using wp core multisite-install --subdomains --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\" --path=\"${VVV_PATH_TO_SITE}/public_html\""
    noroot wp core multisite-install --subdomains --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
    echo " * Multisite install complete"
  elif [ "${WP_TYPE}" = "subdirectory" ]; then
    echo " * Running Multisite install using wp core ${INSTALL_COMMAND} --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\" --path=\"${VVV_PATH_TO_SITE}/public_html\""
    noroot wp core multisite-install --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
    echo " * Multisite install complete"
  fi

  DELETE_DEFAULT_PLUGINS=$(get_config_value 'delete_default_plugins' '')
  echo " *** Do we get to here? ***"
  if [ ! -z "${DELETE_DEFAULT_PLUGINS}" ]; then
    echo " * Deleting the default plugins akismet and hello dolly"
    noroot wp plugin delete akismet
    noroot wp plugin delete hello
  fi

  INSTALL_TEST_CONTENT=$(get_config_value 'install_test_content' "")
  if [ ! -z "${INSTALL_TEST_CONTENT}" ]; then
    echo " * Downloading test content from github.com/poststatus/wptest/master/wptest.xml"
    curl -s https://raw.githubusercontent.com/poststatus/wptest/master/wptest.xml > import.xml
    echo " * Installing the wordpress-importer"
    noroot wp plugin install wordpress-importer
    echo " * Activating the wordpress-importer"
    noroot wp plugin activate wordpress-importer
    echo " * Importing test data"
    noroot wp import import.xml --authors=create
    echo " * Cleaning up import.xml"
    rm import.xml
    echo " * Test content installed"
  fi
}

update_wp() {
  if [[ $(noroot wp core version) > "${WP_VERSION}" ]]; then
    echo " * Installing an older version '${WP_VERSION}' of WordPress"
    noroot wp core update --version="${WP_VERSION}" --force
  else
    echo " * Updating WordPress '${WP_VERSION}'"
    noroot wp core update --version="${WP_VERSION}"
  fi
}

cr__copy_site_composer() {
  echo " * Copying composer.json from server"
  GITLAB_API_URL=https://gitlab.com/api/v4
  GITLAB_TOKEN=MUzSgoBySL-GnkZBSEZ8
  PROJECT=carersresource/cr-site
  FILE=composer.json
  apt-get install -y jq

  PROJECT_ENC=$(echo -n ${PROJECT} | jq -sRr @uri)
  FILE_ENC=$(echo -n ${FILE} | jq -sRr @uri)

  curl --silent --show-error --fail --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${GITLAB_API_URL}/projects/${PROJECT_ENC}/repository/files/${FILE_ENC}/raw?ref=v2" > composer.json
}

cr__run_site_composer() {
  cd "${VVV_PATH_TO_SITE}/public_html"
  noroot composer install
  noroot composer update
}

cr__get_theme() {
  CR_THEME_FOLDER=wp-content/themes/carersresource
  if [ ! -d "${CR_THEME_FOLDER}" ] ; then
    echo " * Clone Carers' Resource theme repository"
    norrot git clone git@gitlab.com:carersresource/cr-theme.git --branch v2 "${CR_THEME_FOLDER}"
    echo " ...done."
  else
    echo " * Update Carers' Resource theme repository"
    cd ${CR_THEME_FOLDER}
    git checkout v2
    git add .
    git stash
    noroot git pull
    cd "${VVV_PATH_TO_SITE}/public_html"
    echo " ...done." 
  fi
}

cr__get_plugins() {
  CR_PLUGIN_FOLDER=wp-content/plugins/cr-plugins
  if [ ! -d "${CR_PLUGIN_FOLDER}" ] ; then
    echo " * Clone Carers' Resource custom plugins repository"
    noroot git clone git@gitlab.com:carersresource/cr-plugins.git --branch v2 ${CR_PLUGIN_FOLDER}
    echo " ...done."
  else
    echo " * Update Carers' Resource custom plugins repository"
    cd ${CR_PLUGIN_FOLDER}
    git checkout v2
    git add .
    git stash
    noroot git pull
    echo "Here."
    cd "${VVV_PATH_TO_SITE}/public_html"
    echo " ...done."
  fi
}

cr__theme_npm_install() {
  echo " * install theme npm modules"
  npm_config_loglevel=error npm install --include-dev --prefix wp-content/themes/carersresource
}

cr__generate_theme_css() {
  echo " * Generate css"
  gulp --cwd wp-content/themes/carersresource less
}

cr__get_webserver_host_keys() {
  #This stops host key authentication failures
  echo " * Adding host keys for webserver to known_hosts"
  ssh-keyscan -H tcr.webfactional.com >> "${HOME}/.ssh/known_hosts"
}

cr__get_site_db() {
  echo " * Get production database"
  if [ ! -f .db ] ; then
    echo " ... create database backups on web server"
    ssh -A tcr@tcr.webfactional.com scripts/latest-db-backup.sh
    echo " ... copy database backup to local"
    scp tcr@tcr.webfactional.com:db-backups/cr-prod-latest.sql "${VVV_PATH_TO_SITE}"
    echo " ... import database"
    noroot wp db import ../cr-prod-latest
    echo " ... change URLs"
    noroot wp search-replace https://www.carersresource.org http://cr-local.test
    echo " ... create file .db to stop datbase being overwritten next provision"
    touch .db
    echp " ... remove file .db from public_html folder to re-import the database"
  fi
}

setup_database
setup_nginx_folders

cd "${VVV_PATH_TO_SITE}/public_html"



if [ "${WP_TYPE}" == "none" ]; then
  echo " * wp_type was set to none, provisioning WP was skipped, moving to Nginx configs"
else
  echo " * Install type is '${WP_TYPE}'"
  # Install and configure the latest stable version of WordPress
  if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-load.php" ]]; then
    download_wordpress "${VVV_PATH_TO_SITE}/public_html" "${WP_VERSION}" "${WP_LOCALE}"
  fi

  if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-config.php" ]]; then
    initial_wpconfig
  fi

  if ! $(noroot wp core is-installed ); then
    echo " * WordPress is present but isn't installed to the database, checking for SQL dumps in wp-content/database.sql or the main backup folder."
    if [ -f "${VVV_PATH_TO_SITE}/public_html/wp-content/database.sql" ]; then
      restore_db_backup "${VVV_PATH_TO_SITE}/public_html/wp-content/database.sql"
    elif [ -f "/srv/database/backups/${VVV_SITE_NAME}.sql" ]; then
      restore_db_backup "/srv/database/backups/${VVV_SITE_NAME}.sql"
    else
      install_wp
    fi
  else
    update_wp
  fi
fi

copy_nginx_configs
setup_wp_config_constants
#install_plugins
#install_themes
cr__get_webserver_host_keys
cr__get_plugins
cr__get_theme
cr__copy_site_composer
cr__run_site_composer
cr__theme_npm_install
cr__generate_theme_css
cr__get_site_db

echo " * Site Template provisioner script completed for ${VVV_SITE_NAME}"
