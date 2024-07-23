#!/bin/sh

set -ea

echo
echo "Starting Labelbase..."
echo

# Setup MariaDB
mkdir -p /run/mysqld
chown -R mysql:mysql /run/mysqld

# check if the 'mysql' system database exists
if [ -d /var/lib/mysql/mysql ]; then
    echo "[i] MariaDB directory already present, skipping creation"
    chown -R mysql:mysql /var/lib/mysql

    # get root password from passwords file, we'll need it later. The passwords file is created and updated on every run (and included in backups)
    export MYSQL_ROOT_PASSWORD=$(yq e '.root' /root/data/start9/passwords.yaml)
    export MYSQL_PASSWORD=$(yq e '.ulabelbase' /root/data/start9/passwords.yaml)
else
    echo "[i] MariaDB data directory not found, creating initial DBs"

    mkdir -p /var/lib/mysql
    chown -R mysql:mysql /var/lib/mysql

    # install system db
    mysql_install_db --user=mysql --ldata=/var/lib/mysql >/dev/null

    # generate the root password
    if [ "$MYSQL_ROOT_PASSWORD" = "" ]; then
        export MYSQL_ROOT_PASSWORD=$(pwgen 16 1)
        echo "[i] MariaDB root Password: $MYSQL_ROOT_PASSWORD"
    fi

    # create a database and give privileges
    # note: Labelbase has the database and username hardcoded to 'labelbase / ulabelbase' with no way to change that
    MYSQL_DATABASE=${MYSQL_DATABASE:-"labelbase"}
    MYSQL_USER=${MYSQL_USER:-"ulabelbase"}
    if [ "$MYSQL_PASSWORD" = "" ]; then
        export MYSQL_PASSWORD=$(pwgen 16 1)
        echo "[i] MariaDB $MYSQL_USER Password: $MYSQL_PASSWORD"
    fi

    tfile=$(mktemp)
    if [ ! -f "$tfile" ]; then
        return 1
    fi

    cat <<EOF >$tfile
USE mysql;
FLUSH PRIVILEGES ;
GRANT ALL ON *.* TO 'root'@'%' identified by '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION ;
GRANT ALL ON *.* TO 'root'@'localhost' identified by '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION ;
SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
DROP DATABASE IF EXISTS test ;
FLUSH PRIVILEGES ;
EOF

    echo "[i] Creating database: $MYSQL_DATABASE"
    echo "[i] with character set: 'utf8' and collation: 'utf8_general_ci'"
    echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8 COLLATE utf8_general_ci;" >>$tfile

    echo "[i] Creating user: $MYSQL_USER with password $MYSQL_PASSWORD"
    echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* to '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" >>$tfile
    echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* to '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';" >>$tfile
    echo "FLUSH PRIVILEGES;" >>$tfile

    # run the script
    /usr/sbin/mysqld --user=mysql --datadir='/var/lib/mysql' --bootstrap --verbose=0 --skip-networking=0 <$tfile
    rm -f $tfile

    echo
    echo 'MariaDB init process done.'
    echo
fi

# Update stats (properties) file

mkdir -p /root/data/start9
cat <<EOF >/root/data/start9/stats.yaml
data:
  MariaDB root password:
    copyable: true
    description: This is the MariaDB root password. Use it with caution!
    masked: true
    qr: false
    type: string
    value: $MYSQL_ROOT_PASSWORD
  MariaDB ulabelbase password:
    copyable: true
    description: This is the MariaDB password for the 'ulabelbase' user. Use it with caution!
    masked: true
    qr: false
    type: string
    value: $MYSQL_PASSWORD
version: 2
EOF

cat <<EOF >/root/data/start9/passwords.yaml
root: $MYSQL_ROOT_PASSWORD
ulabelbase: $MYSQL_PASSWORD
EOF

# Run MariaDB

/usr/sbin/mysqld --user=mysql --datadir='/var/lib/mysql' --console --skip-networking=0 --bind-address=0.0.0.0 &
db_process=$!

# Loop until MariaDB is up
while ! mysql -h 127.0.0.1 -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; do
  echo "Waiting for MariaDB to be up..."
  sleep 1
done

echo "MariaDB is up!"

# Run Labelbase

cd /app

# workaround: run 'manage.py help' to force generation of config.ini, without it, the next step (makemigrations) will fail.
# copy config.ini to a persistent volume and re-use it after restarts
if [ -f /root/data/config.ini ]; then
    cp /root/data/config.ini /app
else
    echo "Executing manage.py help"
    python manage.py help
    cp /app/config.ini /root/data
fi

python manage.py migrate --noinput
python manage.py process_tasks &
gunicorn labellabor.wsgi:application -b 127.0.0.1:8000 --reload &
app_process=$!

# Run nginx

echo "Starting nginx"

nginx -g "daemon off;" &
nginx_process=$!

# hook the TERM signal and wait for all our processes
_term() {
    echo "Caught TERM signal!"
    kill -TERM "$nginx_process" 2>/dev/null
    kill -TERM "$app_process" 2>/dev/null
    kill -TERM "$db_process" 2>/dev/null
}

trap _term TERM
wait $db_process $app_process $nginx_process
