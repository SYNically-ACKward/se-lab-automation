#!/bin/bash
NODE_NAME=$(hostname)

function deploy_pfSense {
    read -p "Enter the number of cores for the VM: " cores
    read -p "Enter the memory size (in MB) for the VM: " memory
    read -p "Enter the size of the new volume on local-lvm storage (in GB, e.g., 50G): " volume_size

    echo "Downloading pfSense ISO..."
    pvesh create /nodes/$NODE_NAME/storage/local/download-url --content iso --filename pfesense.iso --url http://lab-auto.zse-pov.net/pfsense.iso

    echo "Creating pfSense VM..."
    pvesh create /nodes/$NODE_NAME/qemu -vmid 777 -name pfsense -sockets 1 -cores "$cores" -memory "$memory" -ostype l26 -scsi0 local-lvm:${volume_size} -net0 e1000,bridge=vmbr0 -cdrom local:iso/pfesense.iso

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
