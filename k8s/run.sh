#!/bin/bash
set -x
function configsentinel() {
	echo "sentinel monitor ${master[name]} ${master[ip]} ${master[port]} ${master[quorum]}"
	echo "sentinel down-after-milliseconds ${master[name]} ${master[down-after-milliseconds]}"
	echo "sentinel failover-timeout ${master[name]} ${master[failover-timeout]}"
	echo "sentinel parallel-syncs ${master[name]} ${master[parallel-syncs]}"
}

function launchsentinel() {
	declare -a masters
	declare -A master
	# Read all known masters from sentinel service
	IFS=, read -a masters <<<$(timeout ${CONNECTION_TIMEOUT} redis-cli -h ${SENTINEL_SERVICE} -p ${SENTINEL_PORT} --csv SENTINEL masters)
	i=0
	while [ $i -lt ${#masters[@]} ]; do
		# once we have key 'name' and master array is not empty - add master to sentinel congif and clean up array
		if [ "${masters[$i]}" == '"name"' ] && [ ${#master[@]} -gt 0 ]; then
			configsentinel >> $sentinel_conf
			unset master
			declare -A master
		fi
		key=${masters[$i]}
		value=${masters[$i+1]}
		# if value contains " it was split into several values, combine them
		while [ ${value: -1} != '"' ]; do
			i=$(( i + 1))
			value="${value},${masters[$i+1]}"
		done
		master[${key//\"/}]=${value//\"/}
		i=$((i + 2))
	done
        if [ ${#master[@]} -gt 0 ]; then
		configsentinel >> $sentinel_conf
        fi
        unset master
	unset masters 
	egrep '^\s*port \S*\s*$' ${sentinel_conf} >>/dev/null
	if [ "$?" == "0" ]; then
		sed -i -e "s/^\s*port \S*\s*$/port ${SENTINEL_PORT}/" ${sentinel_conf}
	else
		echo "port ${SENTINEL_PORT}" >> ${sentinel_conf}
	fi
	redis-sentinel ${sentinel_conf} --protected-mode no
}

function launchmaster() {
	#Register master on all sentinels
	for sentinel in {$SENTINEL_1,$SENTINEL_2,$SENTINEL_3}; do
		redis-cli -h $sentinel -p ${SENTINEL_PORT} <<- __EOF__
			sentinel monitor ${MASTER_NAME} ${POD_IP} ${REDIS_PORT} ${QUORUM}
			sentinel set ${MASTER_NAME} down-after-milliseconds ${DOWN_AFTER_MILLISECONDS}
			sentinel set ${MASTER_NAME} failover-timeout ${FAILOVER_TIMEOUT}
			sentinel set ${MASTER_NAME} parallel-syncs ${PARALLEL_SYNCS}
		__EOF__
		if [ "$?" != "0" ]; then
			echo "WARNING: Failed to register on ${sentinel}"
		fi
	done
	egrep '^\s*port \S*\s*$' ${redis_conf} >>/dev/null
	if [ "$?" == "0" ]; then
		sed -i -e "s/^\s*port \S*\s*$/port ${REDIS_PORT}/" ${redis_conf}
	else
		echo "port ${REDIS_PORT}" >> ${redis_conf}
	fi

	redis-server ${redis_conf} --protected-mode no
}

function launchserver() {
	unset status
	declare -a status
	IFS=, read -a status <<<$(timeout ${CONNECTION_TIMEOUT} redis-cli -h ${SENTINEL_SERVICE} -p ${SENTINEL_PORT} --csv PING)
	if [[ "${status[0]}" != '"PONG"' ]]; then
		echo "Sentinel service is not available. Exiting..."
                sleep 10
		exit -1
	fi
        unset master
	declare -a master
	IFS=, read -a master <<<$(timeout ${CONNECTION_TIMEOUT} redis-cli -h ${SENTINEL_SERVICE} -p ${SENTINEL_PORT} --csv SENTINEL get-master-addr-by-name ${MASTER_NAME})
	if [ ${#master[@]} -eq 2 ]; then
		unset status
		declare -a status
		read -a status <<<$(redis-cli -h ${master[0]//\"/} -p ${master[1]//\"/} --csv PING)
		if [[ "${status[0]}" != '"PONG"' ]]; then
			echo "Master found, but not reachable"
			# Check if at least one slave is alive
			declare -a slaves
			declare -A slave
			IFS=, read -a slaves <<<$(timeout ${CONNECTION_TIMEOUT} redis-cli -h ${SENTINEL_SERVICE} -p ${SENTINEL_PORT} --csv SENTINEL slaves ${MASTER_NAME})
			i=0
			alive="FALSE"
			while [ $i -lt ${#slaves[@]} -a "$alive" == "FALSE" ]; do
				if [ "${slaves[$i]}" == '"name"' -a ${#slave[@]} -gt 0 ]; then
					unset status
					declare -a status
					IFS=, read -a status <<<$(timeout ${CONNECTION_TIMEOUT} redis-cli -h ${slave[host]} -p ${slave[port]} --csv PING)
					if [ "${status[0]}" == '"PONG"' ]; then
						alive="TRUE"
						break
					fi
					unset slave
					declare -A slave
				fi
				key=${slaves[$i]}
				value=${slaves[$i+1]}
				# if value contains " it was split into several values, combine them
				while [ ${value: -1} != '"' ]; do
					i=$(( i + 1))
					value="${value},${slaves[$i+1]}"
				done
				slave[${key//\"/}]=${value//\"/}
				i=$((i + 2))
			done
			if [ "$alive" == "TRUE" ]; then
				echo "At least one slave is still alive. Exiting..."
				exit -2
			else
				echo "Neither master, nor slaves are alive. Cleanup sentinels and start as a master"
				redis-cli -h ${SENTINEL_1} -p ${SENTINEL_PORT} SENTINEL remove ${MASTER_NAME}
				redis-cli -h ${SENTINEL_2} -p ${SENTINEL_PORT} SENTINEL remove ${MASTER_NAME}
				redis-cli -h ${SENTINEL_3} -p ${SENTINEL_PORT} SENTINEL remove ${MASTER_NAME}
				launchmaster
			fi
		else
			echo "Master found and reachable."
			echo "Starting as slave..."
			# Master found. Starting as a slave
			egrep '^\s*port \S*\s*$' ${redis_conf} >>/dev/null
			if [ "$?" == "0" ]; then
				 sed -i -e "s/^\s*port \S*\s*$/port ${REDIS_PORT}/" ${redis_conf}
			else
				echo "port ${REDIS_PORT}" >> ${redis_conf}
			fi
			echo "slaveof ${master[0]} ${master[1]}" >> ${redis_conf}
			redis-server ${redis_conf} --protected-mode no
		fi
	else
		echo "Master not found."
		echo "Starting as master..."
		# Starting as a master and registering on all Sentinels
		launchmaster
	fi
}


if [ -z ${POD_IP+x} ]; then
	POD_IP=$(hostname -i)
fi
if [ -z ${SENTINEL_1+x} ]; then
	SENTINEL_1=$(echo ${SENTINEL_SERVICE} | sed 's/^\([^.]*\)/\1-r/')
fi
if [ -z ${SENTINEL_2+x} ]; then
	SENTINEL_2=$(echo ${SENTINEL_SERVICE} | sed 's/^\([^.]*\)/\1-g/')
fi
if [ -z ${SENTINEL_3+x} ]; then
	SENTINEL_3=$(echo ${SENTINEL_SERVICE} | sed 's/^\([^.]*\)/\1-b/')
fi

if [ -f ${REDIS_CONFIG} ]; then
	redis_conf=${REDIS_CONFIG}
else
	redis_conf="/k8s/redis.conf"
fi
if [ -f ${SENTINEL_CONFIG} ]; then
	sentinel_conf=${SENTINEL_CONFIG}
else
	sentinel_conf="/k8s/sentinel.conf"
fi

if [[ "${ROLE}" == "server" ]]; then
        echo "Init delay - $INIT_DELAY secons"
        sleep $INIT_DELAY
	launchserver
	exit 0
fi

if [[ "${ROLE}" == "sentinel" ]]; then
	launchsentinel
	exit 0
fi

echo "ROLE should be either server or sentinel"
exit -3
