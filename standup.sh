#!/bin/bash
NODE_NAME=$(hostname)
NICS=4  # Set the number of network interfaces
PFSENSE_INITIAL_PASS="pfsense"
red=$(tput setaf 1)
reset=$(tput sgr0)

# Helper functions

function send_keystrokes() {
    for i in "$@"; do
        pvesh set /nodes/$NODE_NAME/qemu/$VMID/sendkey --key "$i"
        sleep 0.1
    done
}

function cleanup {
    echo -e "${red}Cleaning up packages before exit...${reset}"
    apt-get remove -y expect sshpass
    echo -e "${red}Cleaning up files before exit...${reset}"
    file_list=("standup.sh" "config.xml" "login.exp" "container_1.sh" "container_2.sh" "container_3.sh")
    for file in "${file_list[@]}"; do
        if test -f "/root/$file"; then
            rm "/root/$file"
        fi
    done
}

# End Helper Functions

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

    echo -e "${red}Creating SDN Zone 'lan' and installing dnsmasq...${reset}"

    # Update APT repos, install DNSMASQ and disable default DNSMASQ instance
    apt-get update -qq && apt-get install -y -qq dnsmasq && systemctl disable --now dnsmasq

    # Create SDN Zone
    pvesh create /cluster/sdn/zones -zone lan -type simple -nodes $NODE_NAME -ipam pve

    echo -e "${red}Created SDN Zone 'lan' and installed dnsmasq successfully...${reset}"
    echo -e "${red}Creating VNETs 1-3 in new SDN Zone${reset}"

    # Loop to create VNETs 1-3 in SDN Zone 'lan'
    for (( i=1; i<=3; i++ )); do
        pvesh create /cluster/sdn/vnets --vnet vnet${i} --zone lan
    done

    echo -e "${red}Successfully created VNETs 1-3 in lan zone...${reset}"
    echo -e "${red}Creating subnets and associating with VNETs...${reset}"

    for (( i=1; i<=3; i++ )); do
        lan_var="lan_$i"
        subnet=${!lan_var}  # This uses indirect expansion to get the value of the variable named in lan_var

        pvesh create /cluster/sdn/vnets/vnet$i/subnets --subnet $subnet --type subnet

    done

    echo -e "${red}Successfully created subnets, applying networking changes...${reset}"

    pvesh set /cluster/sdn

    echo -e "${red}Successfully applied networking changes...${reset}"
}

function deploy_pfSense {
    # Set default values
    local ISO_PATH="/var/lib/vz/template/iso/pfesense.iso"
    local default_cores=2
    local default_memory=4096  # in MB
    local default_volume_size="32"  # in GB

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
        echo -e "${red}Downloading pfSense ISO...${reset}"
        pvesh create /nodes/$NODE_NAME/storage/local/download-url --content iso --filename pfesense.iso --url https://se-lab-automation.s3.amazonaws.com/pfesense.iso
    else
        echo -e "${red}pfSense ISO already exists. Skipping download.${reset}"
    fi

    echo -e "${red}Creating pfSense VM...${reset}"

    declare -a pvesh_cmd
    pvesh_cmd=(pvesh create /nodes/$NODE_NAME/qemu -vmid 777 -name pfsense -sockets 1 -cores "$cores" -memory "$memory" -ostype l26 -scsi0 local-lvm:${volume_size})
    nic_order=("vmbr0" "vnet1" "vnet2" "vnet3")
    for (( i=0; i<$NICS; i++ )); do
        bridge=${nic_order[$i]}
        pvesh_cmd+=(-net$i "e1000,bridge=$bridge")
    done

    pvesh_cmd+=(-cdrom "local:iso/pfesense.iso")

    # Execute the pvesh command
    "${pvesh_cmd[@]}"

    echo -e "${red}pfSense VM deployment is complete. Booting up...${reset}"

    pvesh create /nodes/$NODE_NAME/qemu/777/status/start

    echo -e "${red}Waiting for 45 seconds for pfSense initial boot...${reset}"

    sleep 45

    echo -e "${red}Performing pfSense initial installation..."

    install_sequence_1=("ret" "ret" "ret" "ret" "ret" "spc" "ret" "left" "ret")

    for i in "${install_sequence_1[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "$i"
        sleep 1
    done

    echo -e "${red}Waiting 30 seconds for pfSense install to complete before performing reboot...${reset}"

    sleep 30

    pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "ret"

    echo -e "${red}pfSense Operating System install is complete...${reset}"

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
    apt-get update -qq && apt-get install -y -qq sshpass expect

    # Iterate through configuration key sequences to prep for SSH
    key_sequence_1=("1" "ret" "n" "ret" "e" "m" "0" "ret" "ret" "y" "ret" "y" "ret")
    key_sequence_2=("2" "ret" "y" "ret" "n" "ret" "ret" "y" "ret")
    key_sequence_3=("1" "4" "ret" "y" "ret")

    echo -e "${red}Performing key sequence 1...${reset}"

    for i in "${key_sequence_1[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "$i"
        sleep 1
    done

    echo -e "${red}Sleeping for 10 seconds...${reset}"

    sleep 10

    echo -e "${red}Performing key sequence 2...${reset}"

    for i in "${key_sequence_2[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "$i"
        sleep 1
    done

    echo -e "${red}Sleeping for 10 seconds...${reset}"

    sleep 10

    pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "ret"

    sleep 1

    echo -e "${red}Performing key sequence 3...${reset}"

    for i in "${key_sequence_3[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/777/sendkey --key "$i"
        sleep 1
    done

    sleep 1

    echo -e "${red}Performing SSH configuration of pfSense...${reset}"

    # Apply PfSense configuration via SSH
    export SSHPASS=$PFSENSE_INITIAL_PASS

    sshpass -e scp -o StrictHostKeyChecking=no $config_file_path admin@"$pfsense_ip":$remote_file_path

    expect /root/login.exp "$pfsense_ip" "admin" "$PFSENSE_INITIAL_PASS"

    echo -e "${red}PfSense configuration complete - firewall now rebooting...${reset}"
}

function deploy_opnsense {
    # Set default values
    local VMID=778
    local ISO_PATH="/var/lib/vz/template/iso/opnsense.iso"
    local IMG_DIR="/var/lib/vz/private/"
    local IMG_PATH="/var/lib/vz/private/usb1.img"
    local default_cores=2
    local default_memory=4096  # in MB
    local default_volume_size="32"  # in GB
    local mkdir_chars=('m' 'k' 'd' 'i' 'r' 'spc' 'slash' 'm' 'n' 't' 'slash' 'u' 's' 'b' 'ret')
    local mount_chars=('m' 'o' 'u' 'n' 't' 'spc' 'minus' 't' 'spc' 'm' 's' 'd' 'o' 's' 'f' 's' 'spc' 'slash' 'd' 'e' 'v' 'slash' 'd' 'a' '1' 'spc' 'slash' 'm' 'n' 't' 'slash' 'u' 's' 'b' 'ret')
    local cp_chars=('c' 'p' 'spc' 'slash' 'm' 'n' 't' 'slash' 'u' 's' 'b' 'slash' 'c' 'o' 'n' 'f' 'slash' 'c' 'o' 'n' 'f' 'i' 'g' 'dot' 'x' 'm' 'l' 'spc' 'slash' 'c' 'o' 'n' 'f' 'slash' 'c' 'o' 'n' 'f' 'i' 'g' 'dot' 'x' 'm' 'l' 'ret')
    local umount_chars=('u' 'm' 'o' 'u' 'n' 't' 'spc' 'slash' 'm' 'n' 't' 'slash' 'u' 's' 'b' 'ret')
    local exit_chars=('e' 'x' 'i' 't' 'ret')
    local login_chars=('r' 'o' 'o' 't' 'ret' 'o' 'p' 'n' 's' 'e' 'n' 's' 'e' 'ret')


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
        echo -e "${red}Downloading OPNsense ISO...${reset}"
        pvesh create /nodes/$NODE_NAME/storage/local/download-url --content iso --filename opnsense.iso --url https://se-lab-automation.s3.amazonaws.com/opnsense.iso
    else
        echo -e "${red}OPNsense ISO already exists. Skipping download.${reset}"
    fi

    if [ ! -d "$IMG_DIR" ]; then
        echo -e "${red}Creating Private Template director at ${IMG_DIR}...${reset}"
        mkdir $IMG_DIR
    fi

    echo -e "${red}Downloading configuration drive...${reset}"

    wget -O "${IMG_PATH}" https://se-lab-automation.s3.amazonaws.com/usb1.img

    echo -e "${red}Creating OPNsense VM...${reset}"

    declare -a pvesh_cmd
    pvesh_cmd=(pvesh create /nodes/$NODE_NAME/qemu --vmid $VMID -name opnsense --sockets 1 --cores "$cores" --memory "$memory" --ostype l26 --scsihw virtio-scsi-single --scsi0 local-lvm:${volume_size})
    nic_order=("vmbr0" "vnet1" "vnet2" "vnet3")
    for (( i=0; i<$NICS; i++ )); do
        bridge=${nic_order[$i]}
        pvesh_cmd+=(--net$i "e1000,bridge=$bridge")
    done

    pvesh_cmd+=(--cdrom "local:iso/opnsense.iso")

    # Execute the pvesh command
    "${pvesh_cmd[@]}"

    sleep 2

    echo "args: -drive if=none,id=drive-usb0,format=raw,file=/var/lib/vz/private/usb1.img,cache=none -device usb-storage,id=drive-usb0,drive=drive-usb0,removable=on" >> "/etc/pve/qemu-server/${VMID}.conf"

    echo -e "${red}OPNsense VM deployment is complete. Booting up...${reset}"

    pvesh create /nodes/$NODE_NAME/qemu/778/status/start

    echo -e "${red}Waiting for 180 seconds for OPNSENSE initial boot...${reset}"

    end_time=$((SECONDS+180))
    while [ $SECONDS -lt $end_time ]; do
        remaining=$((end_time - SECONDS))
        echo -ne "Time remaining: $remaining seconds\r"
        sleep 1
    done

    echo -e "${red}Performing OPNsense initial installation..."

    install_sequence_1=('i' 'n' 's' 't' 'a' 'l' 'l' 'e' 'r' 'ret' 'o' 'p' 'n' 's' 'e' 'n' 's' 'e' 'ret')
    install_sequence_2=('ret' 'ret' 'down' 'ret' 'ret' 'left' 'ret')

    for i in "${install_sequence_1[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/$VMID/sendkey --key "$i"
    done

    sleep 1

    for i in "${install_sequence_2[@]}"; do
        pvesh set /nodes/$NODE_NAME/qemu/$VMID/sendkey --key "$i"
        sleep .5
    done

    echo -e "${red}Waiting for 150 seconds for OPNsense install...${reset}"

    end_time=$((SECONDS+150))
    while [ $SECONDS -lt $end_time ]; do
        remaining=$((end_time - SECONDS))
        echo -ne "Time remaining: $remaining seconds\r"
        sleep 1
    done

    pvesh set /nodes/$NODE_NAME/qemu/$VMID/sendkey --key "down"
    pvesh set /nodes/$NODE_NAME/qemu/$VMID/sendkey --key "ret"

    echo -e "${red}OPNsense Install is now complete. The firewall is rebooting...${reset}"
    echo -e "${red}Waiting 120 seconds for reboot before initial configuration...${reset}"

    end_time=$((SECONDS+120))
    while [ $SECONDS -lt $end_time ]; do
        remaining=$((end_time - SECONDS))
        echo -ne "Time remaining: $remaining seconds\r"
        sleep 1
    done

    echo -e "${red}Sending login sequence...${reset}"
    send_keystrokes "${login_chars[@]}"
    echo -e "${red}Entering FW Shell...${reset}"
    send_keystrokes "8" "ret"
    echo -e "${red}Creating mountpoint...${reset}"
    send_keystrokes "${mkdir_chars[@]}"
    echo -e "${red}Mounting config drive...${reset}"
    send_keystrokes "${mount_chars[@]}"
    echo -e "${red}Copying configuration file...${reset}"
    send_keystrokes "${cp_chars[@]}"
    sleep 1
    echo -e "${red}Unmounting config drive...${reset}"
    send_keystrokes "${umount_chars[@]}"
    echo -e "${red}Exiting FW Shell...${reset}"
    send_keystrokes "${exit_chars[@]}"
    echo -e "${red}Reloading all services...${reset}"
    send_keystrokes "1" "1" "ret"
    sleep 10
    echo -e "${red}Configuration is now complete...${reset}"
}

function create_servers {
    echo -e "${red}Updating CT Template Repositories...${reset}"
    pveam update

    echo -e "${red}Downloading Ubuntu 22.04 template...${reset}"

    template_name=$(pveam available --section system | grep "ubuntu-22.04-standard_22.04-" | head -n 1 | awk '{print $2}')


    if [ -z "$template_name" ]; then
        echo "No matching Ubuntu 22.04 template found."
    else
        echo -e "${red}Downloading template: $template_name ${reset}"
        pveam download local "$template_name"
    fi

    echo -e "${red}Ensuring SSH keys exist on ProxMox VE Host... Creating if not...${reset}"

    if ! test -f /root/.ssh/id_rsa.pub; then
        ssh-keygen -b 2048 -t rsa -f /root/.ssh/ -q -N ""
        echo -e "${red}Creating SSH keys..."
    else
        echo -e "${red}SSH Keys already exist. Continuing..."
    fi

    echo -e "${red}Creating Ubuntu 22.04 containers...${reset}"

    pvesh create /nodes/$NODE_NAME/lxc \
        --vmid 800 \
        --ostemplate "local:vztmpl/${template_name}" \
        --hostname ubuntu1 \
        --net0 "name=eth0,bridge=vnet2,ip=dhcp,firewall=0" \
        --ostype "ubuntu" \
        --password "zscaler" \
        --storage local-lvm \
        --ssh-public-keys "$(cat /root/.ssh/id_rsa.pub)" \
        --nameserver "10.2.0.1" \
        --start 1

    wget https://raw.githubusercontent.com/SYNically-ACKward/se-lab-automation/main/container_1.sh

    pct push 800 /root/container_1.sh /root/container_1.sh

    pct exec 800 -- /bin/bash /root/container_1.sh
}

function main_menu {
    while true; do
        echo "Select an option:"
        echo "1) Configure Networking"
        echo "2) Deploy pfSense"
        echo "3) Apply pfSense Base Config"
        echo "4) Deploy and configure OPNsense"
        echo "5) Create 'Server' Containers"
        # echo "6) Create 'User' VMs"
        # echo "7) Create 'IOT' Containers"
        
        echo "q) Quit"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) configure_sdn ;;
            2) deploy_pfSense ;;
            3) configure_pfsense ;;
            4) deploy_opnsense ;;
            5) create_servers ;;
            q) cleanup
               echo "Exiting the script."
               exit 0 ;;
            *) echo "Invalid option, please try again." ;;
        esac
    done
}

main_menu
