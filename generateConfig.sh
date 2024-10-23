#!/usr/bin/env bash

set -o pipefail

MAILCOW_HOSTNAME=$(hostname -I | awk '{print $1}')
DIR=$(pwd)
SKIP_BRANCH=n
MAILCOW_BRANCH="master"

check_busybox() {
  if $1 --help 2>&1 | head -n 1 | grep -q -i "busybox"; then
    exit 1
  fi
}

check_busybox grep
check_busybox cp
check_busybox sed

if [ -a /etc/timezone ]; then
  DETECTED_TZ=$(cat /etc/timezone)
elif [ -a /etc/localtime ]; then
  DETECTED_TZ=$(readlink /etc/localtime|sed -n 's|^.*zoneinfo/||p')
fi

while [ -z "${MAILCOW_TZ}" ]; do
  if [ -z "${DETECTED_TZ}" ]; then
    read -p "Timezone: " -e MAILCOW_TZ
  else
    read -p "Timezone [${DETECTED_TZ}]: " -e MAILCOW_TZ
    [ -z "${MAILCOW_TZ}" ] && MAILCOW_TZ=${DETECTED_TZ}
  fi
done

MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

if [ -z "${SKIP_CLAMD}" ]; then
  if [ "${MEM_TOTAL}" -le "2621440" ]; then
    read -r -p  "Do you want to disable ClamAV now? [Y/n] " response
    case $response in
      [nN][oO]|[nN])
        SKIP_CLAMD=n
        ;;
      *)
        SKIP_CLAMD=y
      ;;
    esac
  else
    SKIP_CLAMD=n
  fi
fi

if [ -z "${SKIP_SOLR}" ]; then
  if [ "${MEM_TOTAL}" -le "2097152" ]; then
    SKIP_SOLR=y
  elif [ "${MEM_TOTAL}" -le "3670016" ]; then
    read -r -p  "Do you want to disable Solr now? [Y/n] " response
    case $response in
      [nN][oO]|[nN])
        SKIP_SOLR=n
        ;;
      *)
        SKIP_SOLR=y
      ;;
    esac
  else
    SKIP_SOLR=n
  fi
fi

if [ ! -z "${MAILCOW_BRANCH}" ]; then
  git_branch=${MAILCOW_BRANCH}
fi

[ ! -f $DIR/data/conf/rspamd/override.d/worker-controller-password.inc ] && echo '# Placeholder' > $DIR/data/conf/rspamd/override.d/worker-controller-password.inc

cat << EOF > $DIR/mailcow.conf
MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
MAILCOW_PASS_SCHEME=BLF-CRYPT
DBNAME=mailcow
DBUSER=mailcow
DBPASS=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 2> /dev/null | head -c 28)
DBROOT=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 2> /dev/null | head -c 28)
HTTP_PORT=80
HTTP_BIND=
HTTPS_PORT=443
HTTPS_BIND=
SMTP_PORT=25
SMTPS_PORT=465
SUBMISSION_PORT=587
IMAP_PORT=143
IMAPS_PORT=993
POP_PORT=110
POPS_PORT=995
SIEVE_PORT=4190
DOVEADM_PORT=127.0.0.1:19991
SQL_PORT=127.0.0.1:13306
SOLR_PORT=127.0.0.1:18983
REDIS_PORT=127.0.0.1:7654
TZ=${MAILCOW_TZ}
COMPOSE_PROJECT_NAME=mailcowdockerized
DOCKER_COMPOSE_VERSION=${COMPOSE_VERSION}
ACL_ANYONE=disallow
MAILDIR_GC_TIME=7200
#ADDITIONAL_SAN=imap.*,smtp.*
#ADDITIONAL_SAN=srv1.example.net
#ADDITIONAL_SAN=imap.*,srv1.example.com
ADDITIONAL_SAN=
AUTODISCOVER_SAN=y
ADDITIONAL_SERVER_NAMES=
SKIP_LETS_ENCRYPT=n
ENABLE_SSL_SNI=n
SKIP_IP_CHECK=n
SKIP_HTTP_VERIFICATION=n
SKIP_UNBOUND_HEALTHCHECK=n
SKIP_CLAMD=${SKIP_CLAMD}
SKIP_SOGO=n
SKIP_SOLR=${SKIP_SOLR}
SOLR_HEAP=1024
ALLOW_ADMIN_EMAIL_LOGIN=n
USE_WATCHDOG=y
#WATCHDOG_NOTIFY_EMAIL=a@example.com,b@example.com,c@example.com
#WATCHDOG_NOTIFY_EMAIL=
#WATCHDOG_NOTIFY_WEBHOOK=https://discord.com/api/webhooks/XXXXXXXXXXXXXXXXXXX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
#WATCHDOG_NOTIFY_WEBHOOK_BODY='{"username": "mailcow Watchdog", "content": "**${SUBJECT}**\n${BODY}"}'
WATCHDOG_NOTIFY_BAN=n
WATCHDOG_NOTIFY_START=y
#WATCHDOG_SUBJECT=
WATCHDOG_EXTERNAL_CHECKS=n
WATCHDOG_VERBOSE=n
LOG_LINES=9999
IPV4_NETWORK=172.22.1
IPV6_NETWORK=fd4d:6169:6c63:6f77::/64
#SNAT_TO_SOURCE=
#SNAT6_TO_SOURCE=
#API_KEY=
#API_KEY_READ_ONLY=
#API_ALLOW_FROM=172.22.1.1,127.0.0.1
MAILDIR_SUB=Maildir
SOGO_EXPIRE_SESSION=480
DOVECOT_MASTER_USER=
DOVECOT_MASTER_PASS=
ACME_CONTACT=
WEBAUTHN_ONLY_TRUSTED_VENDORS=n
SPAMHAUS_DQS_KEY=
DISABLE_NETFILTER_ISOLATION_RULE=n
EOF

mkdir -p $DIR/data/assets/ssl

chmod 600 $DIR/mailcow.conf

openssl req -x509 -newkey rsa:4096 -keyout $DIR/data/assets/ssl-example/key.pem -out $DIR/data/assets/ssl-example/cert.pem -days 365 -subj "/C=DE/ST=NRW/L=Willich/O=mailcow/OU=mailcow/CN=${MAILCOW_HOSTNAME}" -sha256 -nodes
cp -n -d $DIR/data/assets/ssl-example/*.pem $DIR/data/assets/ssl/

mailcow_git_version=$(git describe --tags `git rev-list --tags --max-count=1`)

if [ $? -eq 0 ]; then
  echo '<?php' > $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_VERSION="'$mailcow_git_version'";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_LAST_GIT_VERSION="";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_OWNER="mailcow";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_REPO="mailcow-dockerized";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_URL="https://github.com/mailcow/mailcow-dockerized";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_COMMIT="'$mailcow_git_commit'";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_COMMIT_DATE="'$mailcow_git_commit_date'";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_BRANCH="'$git_branch'";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_UPDATEDAT='$(date +%s)';' >> $DIR/data/web/inc/app_info.inc.php
  echo '?>' >> $DIR/data/web/inc/app_info.inc.php
else
  echo '<?php' > $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_VERSION="'$mailcow_git_version'";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_LAST_GIT_VERSION="";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_OWNER="mailcow";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_REPO="mailcow-dockerized";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_URL="https://github.com/mailcow/mailcow-dockerized";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_COMMIT="";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_GIT_COMMIT_DATE="";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_BRANCH="'$git_branch'";' >> $DIR/data/web/inc/app_info.inc.php
  echo '  $MAILCOW_UPDATEDAT='$(date +%s)';' >> $DIR/data/web/inc/app_info.inc.php
  echo '?>' >> $DIR/data/web/inc/app_info.inc.php
fi
