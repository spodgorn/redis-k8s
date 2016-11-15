#!/bin/bash
if [[ -z "${POD_IP+x}" ]]; then 
	POD_IP=$(hostname -i);
fi
if [[ "${ROLE}" == "server" ]]; then  
	redis-cli -h ${POD_IP} -p ${REDIS_PORT} --csv role
	exit $?
fi
if [[ "${ROLE}" == "sentinel" ]]; then  
	redis-cli -h ${POD_IP} -p ${SENTINEL_PORT} --csv role
	exit $?
fi
