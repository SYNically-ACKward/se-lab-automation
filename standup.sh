#!/bin/bash
NODE_NAME=$(hostname)
NICS=5  # Set the number of network interfaces
ISO_PATH="/var/lib/vz/template/iso/pfesense.iso"


function deploy_pfSense {
    # Set default values
    local default_cores=4
    local default_memory=8192  # in MB
    local default_volume_size="50G"  # in GB

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

    for (( i=0; i<$NICS; i++ )); do
        pvesh_cmd+=(-net$i "e1000,bridge=vmbr0")
    done

    pvesh_cmd+=(-cdrom "local:iso/pfesense.iso")

    # Execute the pvesh command
    "${pvesh_cmd[@]}"

    echo "pfSense VM deployment is complete."
}

function main_menu {
    while true; do
        echo "Select an option:"
        echo "1) Deploy pfSense"
        echo "2) Quit"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) deploy_pfSense ;;
            2) echo "Exiting the script."
               exit 0 ;;
            *) echo "Invalid option, please try again." ;;
        esac
    done
}

main_menu
