FROM python:3.11-slim-bookworm

# these are specified in Makefile
ARG PLATFORM
ARG YQ_VERSION
ARG YQ_SHA

ENV PYTHONUNBUFFERED 1

WORKDIR /app

COPY ./Labelbase/django/requirements.txt /app

# Install necessary packages
RUN \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends \
    # install wget and certificates
    ca-certificates wget \
    # install mariadb server and client
    mariadb-server mariadb-client pwgen \
    # Labelbase
    nginx default-libmysqlclient-dev \
    pkg-config build-essential \
    cron logrotate \
    libpcre3-dev \
    default-mysql-client && \
  # configure Labelbase
  pip install --upgrade pip && \
  pip install --no-cache-dir -r /app/requirements.txt && \
  # clean up to keep container small
  apt-get purge -y --auto-remove pkg-config build-essential && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN \
  # install yq
  wget -qO /tmp/yq https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${PLATFORM} && \
  echo "${YQ_SHA} /tmp/yq" | sha256sum -c || exit 1 && \ 
  mv /tmp/yq /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# remove default mariadb config and data files,
# so we can manually handle db initalization
RUN \
  rm -r /etc/mysql/mariadb.conf.d/50-server.cnf && \
  rm -r /var/lib/mysql/

# add Labelbase
COPY assets/nginx.conf /etc/nginx/sites-available/default
COPY ./Labelbase/django /app

# create migrations and static files, working around issues with manage.py of Labelbase
# need to run 'manage.py help' to create a /app/config.ini first
RUN \
  MYSQL_PASSWORD=not_used python manage.py help >/dev/null && \
  python manage.py collectstatic --noinput && \
  rm /app/config.ini

COPY ./docker_entrypoint.sh /usr/local/bin/docker_entrypoint.sh
