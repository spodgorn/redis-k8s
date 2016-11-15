#!/bin/bash
set -x
if [[ -z "${POD_IP+x}" ]]; then
		POD_IP=$(hostname -i);
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
if [[ "$ROLE" == "sentinel" ]]; then
	declare -a status
	IFS=, read -a status <<<$(redis-cli -h ${POD_IP} -p ${SENTINEL_PORT} --csv role)
	if [[ "${status[0]//\"/}" == "sentinel" ]]; then
		echo 0
	else
		echo -1
	fi
fi
if [[ "${ROLE}" == "server" ]]; then
	declare -a status
	IFS=, read -a status <<<$(redis-cli -h ${POD_IP} -p ${REDIS_PORT} --csv role)
	case ${status[0]//\"/} in
		master)
			#Register master on all sentinels
			for sentinel in {$SENTINEL_1,$SENTINEL_2,$SENTINEL_3}; do
				IFS=, read -a status <<<$(redis-cli -h $sentinel -p ${SENTINEL_PORT} --csv role)
				found=false
				for master in ${status[*]}; do
					if [[ "${master//\"/}" == "${MASTER_NAME}" ]]; then
						found=true
					fi
				done
				if ! $found; then
					redis-cli -h $sentinel -p ${SENTINEL_PORT} <<- __EOF__
						sentinel monitor ${MASTER_NAME} ${POD_IP} ${REDIS_PORT} ${QUORUM}
						sentinel set ${MASTER_NAME} down-after-milliseconds ${DOWN_AFTER_MILLISECONDS}
						sentinel set ${MASTER_NAME} failover-timeout ${FAILOVER_TIMEOUT}
						sentinel set ${MASTER_NAME} parallel-syncs ${PARALLEL_SYNCS}
					__EOF__
					if [ "$?" != "0" ]; then
						echo "WARNING: Failed to register on ${sentinel}"
					fi
				fi
			done
			echo "master - 0"
			;;
		slave)
			echo "slave - 0"
			;;
		*)
			echo "else -1"
			;;
	esac
fi
echo "default - 0"
