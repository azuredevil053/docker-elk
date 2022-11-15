#!/usr/bin/env bash

set -eu
set -o pipefail


source "$(dirname ${BASH_SOURCE[0]})/lib/testing.sh"


cid_es="$(container_id elasticsearch)"
cid_fl="$(container_id fleet-server)"

ip_es="$(service_ip elasticsearch)"
ip_fl="$(service_ip fleet-server)"

log 'Waiting for readiness of Elasticsearch'
poll_ready "$cid_es" "http://${ip_es}:9200/" -u 'elastic:testpasswd'

log 'Waiting for readiness of Fleet Server'
poll_ready "$cid_fl" "http://${ip_fl}:8220/api/status"

# We expect to find metrics entries using the following query:
#
#   agent.name:"fleet-server"
#   AND agent.type:"metricbeat"
#   AND event.module:"system"
#   AND event.dataset:"system.cpu"
#   AND metricset.name:"cpu"
#
log 'Searching a document generated by Fleet Server'

declare response
declare -i count

declare -i was_retried=0

# retry for max 60s (30*2s)
for _ in $(seq 1 30); do
	response="$(curl "http://${ip_es}:9200/metrics-system.cpu-default/_search?q=agent.name:%22fleet-server%22%20AND%20agent.type:%22metricbeat%22%20AND%20event.module:%22system%22%20AND%20event.dataset:%22system.cpu%22%20AND%20metricset.name:%22cpu%22&pretty" -s -u elastic:testpasswd)"

	set +u  # prevent "unbound variable" if assigned value is not an integer
	count="$(jq -rn --argjson data "${response}" '$data.hits.total.value')"
	set -u

	if (( count > 0 )); then
		break
	fi

	was_retried=1
	echo -n 'x' >&2
	sleep 2
done
if ((was_retried)); then
	# flush stderr, important in non-interactive environments (CI)
	echo >&2
fi

echo "$response"
# Elastic Agent buffers metrics until Elasticsearch becomes ready, so we
# tolerate multiple results
if (( count == 0 )); then
	echo 'Expected at least 1 document'
	exit 1
fi
