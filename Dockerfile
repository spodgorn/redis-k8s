FROM redis:3.2.5

COPY k8s /k8s

ENV INIT_DELAY 0
ENV MASTER_NAME redis-master
ENV DOWN_AFTER_MILLISECONDS 3000
ENV FAILOVER_TIMEOUT 9000
ENV PARALLEL_SYNCS 1
ENV QUORUM 2
ENV CONNECTION_TIMEOUT 2
ENV REDIS_PORT 6379
ENV SENTINEL_PORT 26379
ENV SENTINEL_SERVICE redis-sentinel
ENV REDIS_CONFIG /k8s/redis.conf
ENV SENTINEL_CONFIG /k8s/sentinel.conf

CMD [ "/k8s/run.sh" ]

ENTRYPOINT [ "bash", "-c" ]
