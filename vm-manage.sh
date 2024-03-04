#!/bin/sh

VM_PREFIX='test'
YELLOW='\e[1;33m'
RED='\e[31m'
GREEN='\e[32m'
END_COLOR='\e[0m'

if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
	echo "Usage: ./vm-manage.sh project_name service_account [/path/to/output/table]"
	exit 1
fi

create_vm() {
	gcloud compute instances create test-$1 \
		--project=$2 \
		--zone=$1 \
		--machine-type=n1-standard-1 \
		--network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
		--maintenance-policy=TERMINATE \
		--provisioning-model=STANDARD \
		--service-account=$3 \
		--scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
		--accelerator=count=1,type=nvidia-tesla-t4 \
		--create-disk=auto-delete=yes,boot=yes,device-name="$VM_PREFIX-$1",image=projects/debian-cloud/global/images/debian-12-bookworm-v20240213,mode=rw,size=10,type=projects/"$2"/zones/"$1"/diskTypes/pd-balanced \
		--no-shielded-secure-boot \
		--shielded-vtpm \
		--shielded-integrity-monitoring \
		--labels=goog-ec-src=vm_add-gcloud \
		--reservation-affinity=any
}

delete_vm() {
	yes Y | gcloud compute instances delete "$VM_PREFIX-$1" --zone=$1 2>/dev/null
}

append_csv() {
	echo "$1,$2,$3" >>"$4"
}

output_table="$3"
if [ -z "$output_table" ]; then
	output_table="zones.csv"
fi
if [ -f "$output_table" ]; then
	echo "$output_table already existed. Terminating..."
	exit 2
else
	append_csv "Zone" "GPU available" "GPU allocated to VM" "$output_table"
fi
zones_list=$(gcloud compute zones list | awk '{print $1}' | tail -n +2)
# If google ssh key is not genertaed, the key pair
# with no passphrase will be generated.
echo -e "\n\n" | gcloud compute ssh foo --zone=foo 2>/dev/null

for zone in $zones_list; do
	echo "Trying to create intance in zone $zone..."
	message="$(create_vm $zone $1 $2 2>&1)"
	if [ $? -eq 0 ]; then
		echo -e "${GREEN}Instance created in zone $zone!${END_COLOR}"
		# Wait for a while for the instance to be setup.
		sleep 10
		echo "Logging into the instance..."
		echo -e "${YELLOW}\$ lspci | grep -i nvidia${END_COLOR}"
		num_fail=0
		while [ "$num_fail" -le 6 ]; do
			output=$(gcloud compute ssh "$VM_PREFIX-$zone" --zone="$zone" --command="lspci | grep -i nvidia" 2>/dev/null)
			if [ $? -eq 0 ]; then
				break
			fi
			num_fail=$(expr $num_fail + 1)
			sleep 5
		done

		if [ "$num_fail" -eq 7 ]; then
			append_csv "$zone" "yes" "no" "$output_table"
			echo -e "${RED}Cannot log into the instace.${END_COLOR}"
		else
			append_csv "$zone" "yes" "yes" "$output_table"
			echo -e "${YELLOW}$output${END_COLOR}"
		fi
		sleep 5
		echo "Deleting instance in zone $zone..."
		delete_vm $zone
		echo -e "Instance deleted!\n"
	else
		echo "$message" | grep "not found" >/dev/null 2>/dev/null
		if [ "$?" -eq 0 ]; then
			append_csv "$zone" "no" "no" "$output_table"
		else
			append_csv "$zone" "yes" "no" "$output_table"
		fi
		echo -e "${RED}$message\n${END_COLOR}"
	fi
done
