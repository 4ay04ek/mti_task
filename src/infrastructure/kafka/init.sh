#!/bin/sh
set -eu
for topic in ticket.events telemetry.logs; do
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --create --if-not-exists \
    --topic "$topic" --partitions 3 --replication-factor 1
done
