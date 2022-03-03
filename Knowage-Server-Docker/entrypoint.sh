#!/bin/bash
set -e

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

file_env "DB_HOST"
file_env "DB_PORT"
file_env "DB_DB"
file_env "DB_USER"
file_env "DB_PASS"
file_env "DB_CONNECTION_POOL_SIZE"   "20"
file_env "DB_CONNECTION_MAX_IDLE"    "10"
file_env "DB_CONNECTION_WAIT_MS"     "300"

file_env "CACHE_DB_HOST"
file_env "CACHE_DB_PORT"
file_env "CACHE_DB_DB"
file_env "CACHE_DB_USER"
file_env "CACHE_DB_PASS"
file_env "CACHE_DB_CONNECTION_POOL_SIZE"   "20"
file_env "CACHE_DB_CONNECTION_MAX_IDLE"    "10"
file_env "CACHE_DB_CONNECTION_WAIT_MS"     "300"

file_env "AJP_SECRET"

# Wait for MySql
./wait-for-it.sh ${DB_HOST}:${DB_PORT} -- echo "MySql is up!"

# Placeholder created after the first boot of the container
CONTAINER_INITIALIZED_PLACEHOLDER=/.CONTAINER_INITIALIZED

# Check if this is the first boot
if [ ! -f "$CONTAINER_INITIALIZED_PLACEHOLDER" ]
then
	file_env "HMAC_KEY"
	file_env "PASSWORD_ENCRYPTION_SECRET"
	file_env "PUBLIC_ADDRESS"

	# Generate default values for the optional env vars
	if [[ -z "$PUBLIC_ADDRESS" ]]
	then
	        #get the address of container
	        #example : default via 172.17.42.1 dev eth0 172.17.0.0/16 dev eth0 proto kernel scope link src 172.17.0.109
	        PUBLIC_ADDRESS=`ip route | grep src | awk '{print $9}'`
	fi
	
	if [ -z "$HMAC_KEY" ]
	then
		echo "The HMAC_KEY environment variable is needed"
		exit -1
	fi
	
	if [ -z "$PASSWORD_ENCRYPTION_SECRET" ]
	then
		echo "The PASSWORD_ENCRYPTION_SECRET environment variable is needed"
		exit -1
	fi
	
	if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_DB"   ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]
	then
		echo "The DB_HOST, DB_PORT, DB_DB, DB_USER, DB_PASS environment variables are needed"
		exit -1
	fi

	if [ -z "$CACHE_DB_HOST" ] || [ -z "$CACHE_DB_PORT" ] || [ -z "$CACHE_DB_DB"   ] || [ -z "$CACHE_DB_USER" ] || [ -z "$CACHE_DB_PASS" ]
	then
		echo "The CACHE_DB_HOST, CACHE_DB_PORT, CACHE_DB_DB, CACHE_DB_USER, CACHE_DB_PASS environment variables are needed"
		exit -1
	fi

	if [ -z "$AJP_SECRET" ]
	then
	        AJP_SECRET=$( openssl rand -base64 32 )
	        echo "###################################################################"
	        echo "#"
	        echo "# Random generated AJP secret:"
	        echo "#   ${AJP_SECRET}"
	        echo "#"
	fi

	# Replace the address of container inside server.xml
	sed -i "s|http:\/\/.*:8080|http:\/\/${PUBLIC_ADDRESS}:8080|g" ${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml
	sed -i "s|http:\/\/.*:8080\/knowage|http:\/\/localhost:8080\/knowage|g" ${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml
	sed -i "s|http:\/\/localhost:8080|http:\/\/${PUBLIC_ADDRESS}:8080|g" ${KNOWAGE_DIRECTORY}/apache-tomcat/webapps/knowage/WEB-INF/web.xml
	
	# Insert knowage metadata into db if it doesn't exist
	result=`mysql -h${DB_HOST} -P${DB_PORT} -u${DB_USER} -p${DB_PASS} ${DB_DB} -e "SHOW TABLES LIKE '%SBI_%';"`
	if [ -z "$result" ]; then
		mysql -h${DB_HOST} -P${DB_PORT} -u${DB_USER} -p${DB_PASS} ${DB_DB} --execute="source ${MYSQL_SCRIPT_DIRECTORY}/MySQL_create.sql"
		mysql -h${DB_HOST} -P${DB_PORT} -u${DB_USER} -p${DB_PASS} ${DB_DB} --execute="source ${MYSQL_SCRIPT_DIRECTORY}/MySQL_create_quartz_schema.sql"
	fi
	
	# Set DB connection for Knowage metadata
	xmlstarlet ed -P -L \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/knowage']/@url"      -v "jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_DB}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/knowage']/@username" -v "${DB_USER}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/knowage']/@password" -v "${DB_PASS}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/knowage']/@maxTotal"       -v "${DB_CONNECTION_POOL_SIZE}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/knowage']/@maxIdle"        -v "${DB_CONNECTION_MAX_IDLE}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/knowage']/@maxWaitMillis"  -v "${DB_CONNECTION_WAIT_MS}" \
		${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml
	
	# Set DB connection for Knowage cache
	xmlstarlet ed -P -L \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/ds_cache']/@url"      -v "jdbc:mysql://${CACHE_DB_HOST}:${CACHE_DB_PORT}/${CACHE_DB_DB}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/ds_cache']/@username" -v "${CACHE_DB_USER}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/ds_cache']/@password" -v "${CACHE_DB_PASS}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/ds_cache']/@maxTotal"       -v "${CACHE_DB_CONNECTION_POOL_SIZE}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/ds_cache']/@maxIdle"        -v "${CACHE_DB_CONNECTION_MAX_IDLE}" \
		-u "//Server/GlobalNamingResources/Resource[@name='jdbc/ds_cache']/@maxWaitMillis"  -v "${CACHE_DB_CONNECTION_WAIT_MS}" \
		${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml

	# Set HMAC key
	xmlstarlet ed -P -L \
		-u "//Server/GlobalNamingResources/Environment[@name='hmacKey']/@value" -v "${HMAC_KEY}" \
		${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml
	
	# Set password encryption key
	echo $PASSWORD_ENCRYPTION_SECRET > ${KNOWAGE_DIRECTORY}/apache-tomcat/conf/passwordEncryptionSecret

	# Set AJP secret
	xmlstarlet ed -P -L \
	        -d "//Server/Service/Connector[contains(@protocol, 'AJP')]/@secretRequired" \
	        ${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml
	xmlstarlet ed -P -L \
	        -d "//Server/Service/Connector[contains(@protocol, 'AJP')]/@secret" \
	        ${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml
	xmlstarlet ed -P -L \
	        -i "//Server/Service/Connector[contains(@protocol, 'AJP')]" -t attr -n secretRequired -v "true" \
	        ${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml
	xmlstarlet ed -P -L \
	        -i "//Server/Service/Connector[contains(@protocol, 'AJP')]" -t attr -n secret -v "${AJP_SECRET}" \
	        ${KNOWAGE_DIRECTORY}/apache-tomcat/conf/server.xml

	# Create the placeholder to prevent multiple initializations
	touch "$CONTAINER_INITIALIZED_PLACEHOLDER"
fi

exec "$@"
