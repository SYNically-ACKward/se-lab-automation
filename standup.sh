#!/bin/bash
NODE_NAME=$(hostname)
NICS=5  # Set the number of network interfaces
ISO_PATH="/var/lib/vz/template/iso/pfesense.iso"
PFSENSE_INITIAL_PASS="pfsense"


function deploy_pfSense {
    # Set default values
    local default_cores=4
    local default_memory=8192  # in MB
    local default_volume_size="50"  # in GB

    echo "Enter the number of cores for the VM (default: $default_cores): "
    read cores
    cores=${cores:-$default_cores}

    echo "Enter the memory size (in MB) for the VM (default: $default_memory): "
    read memory
    memory=${memory:-$default_memory}

    echo "Enter the size of the new volume on local-lvm storage (default: $default_volume_size): "
    read volume_size
    volume_size=${volume_size:-$default_volume_size}

    if [ ! -f "$ISO_PATH" ]; then
        echo "Downloading pfSense ISO..."
        pvesh create /nodes/$NODE_NAME/storage/local/download-url --content iso --filename pfesense.iso --url http://lab-auto.zse-pov.net/pfsense.iso
    else
        echo "pfSense ISO already exists. Skipping download."
    fi

    echo "Creating pfSense VM..."

    declare -a pvesh_cmd
    pvesh_cmd=(pvesh create /nodes/$NODE_NAME/qemu -vmid 777 -name pfsense -sockets 1 -cores "$cores" -memory "$memory" -ostype l26 -scsi0 local-lvm:${volume_size})
    nic_order=("vmbr0" "vmbr0" "vnet1" "vnet2" "vnet3")
    for (( i=0; i<$NICS; i++ )); do
        bridge=${nic_order[$i]}
        pvesh_cmd+=(-net$i "e1000,bridge=$bridge")
    done

    pvesh_cmd+=(-cdrom "local:iso/pfesense.iso")

    # Execute the pvesh command
    "${pvesh_cmd[@]}"

    echo "pfSense VM deployment is complete."
}

function configure_sdn {
    local default_lan_1="10.1.0.0/24"
    local default_lan_2="10.2.0.0/24"
    local default_lan_3="10.3.0.0/24"

    echo "Enter the subnet (in CIDR format) for LAN 1 (default: $default_lan_1):"
    read lan_1
    lan_1=${lan_1:-$default_lan_1}

    echo "Enter the subnet (in CIDR format) for LAN 2 (default: $default_lan_2):"
    read lan_2
    lan_2=${lan_2:-$default_lan_2}

    echo "Enter the subnet (in CIDR format) for LAN 3 (default: $default_lan_3):"
    read lan_3
    lan_3=${lan_3:-$default_lan_3}

    echo "Creating SDN Zone 'lan' and installing dnsmasq ..."

    # Update APT repos, install DNSMASQ and disable default DNSMASQ instance
    apt update && apt install -y dnsmasq && systemctl disable --now dnsmasq

    # Create SDN Zone
    pvesh create /cluster/sdn/zones -zone lan -type simple -dhcp dnsmasq -nodes $NODE_NAME -ipam pve

    echo "Created SDN Zone 'lan' and installed dnsmasq successfully..."
    echo "Creating VNETs 1-3 in new SDN Zone"

    # Loop to create VNETs 1-3 in SDN Zone 'lan'
    for (( i=1; i<=3; i++ )); do
        pvesh create /cluster/sdn/vnets --vnet vnet${i} --zone lan
    done

    echo "Successfully created VNETs 1-3 in lan zone..."
    echo "Creating subnets and associating with VNETs..."

    for (( i=1; i<=3; i++ )); do
	    lan_var="lan_$i"
	    subnet=${!lan_var}  # This uses indirect expansion to get the value of the variable named in lan_var
	    # Remove the CIDR notation
	    subnet_base=${subnet%/*}  # This strips off the CIDR part, e.g., /24

	    # Get the first three octets of the subnet base and append .1
	    IFS='.' read -r -a octets <<< "$subnet_base"  # Split the IP into an array by dot
	    gateway="${octets[0]}.${octets[1]}.${octets[2]}.1"  # Reconstruct the gateway IP
	    dhcp_start="${octets[0]}.${octets[1]}.${octets[2]}.20"
	    dhcp_end="${octets[0]}.${octets[1]}.${octets[2]}.254"

	    pvesh create /cluster/sdn/vnets/vnet$i/subnets --subnet $subnet --type subnet --gateway $gateway --dhcp-range start-address=$dhcp_start,end-address=$dhcp_end

    done

    echo "Successfully created subnets, applying networking changes..."

    pvesh set /cluster/sdn

    echo "Successfully applied networking changes..."
}

function configure_pfsense {
    local config_file_link="https://raw.githubusercontent.com/SYNically-ACKward/se-lab-automation/main/config.xml"
    local login_script_link="https://raw.githubusercontent.com/SYNically-ACKward/se-lab-automation/main/login.exp"
    config_file_path="/root/config.xml"
    remote_file_path="/cf/conf/config.xml"

    echo "Enter the WAN IP address shown in the PfSense Console screen:"
    read pfsense_ip

    wget $config_file_link
    wget $login_script_link
    # Install sshpass and expect for configuration
    apt update && apt install -y sshpass expect

    # Iterate through configuration key sequences to prep for SSH
    key_sequence_1=("1" "ret" "n" "ret" "e" "m" "0" "ret" "ret" "y" "ret" "y" "ret")
    key_sequence_2=("2" "ret" "y" "ret" "n" "ret" "ret" "y" "ret")
    key_sequence_3=("1" "4" "ret" "y" "ret")

    for i in "${key_sequence_1[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "$i"
        sleep 1
    done

    sleep 10

    for i in "${key_sequence_2[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "$i"
        sleep 1
    done

    sleep 10

    pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "ret"

    sleep 1

    for i in "${key_sequence_3[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "$i"
        sleep 1
    done

    sleep 1

    # Apply PfSense configuration via SSH
    export SSHPASS=$PFSENSE_INITIAL_PASS

    /root/login.exp "$pfsense_ip" "admin" "$PFSENSE_INITIAL_PASS"

    echo "PfSense configuration complete - firewall now rebooting..."
}

function main_menu {
    while true; do
        echo "Select an option:"
        echo "1) Configure Networking"
        echo "2) Deploy pfSense"
        echo "3) Apply pfSense Base Config"
        echo "q) Quit"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) configure_sdn ;;
            2) deploy_pfSense ;;
            3) configure_pfsense ;;
            q) echo "Exiting the script."
               exit 0 ;;
            *) echo "Invalid option, please try again." ;;
        esac
    done
}

main_menu
