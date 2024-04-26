# Purpose

This script is intended to stand up a base lab environment on a *fresh* ProxMox VE host. 

# Usage

To invoke the script ssh to your ProxMox VE instance as the root user and run the command `wget https://raw.githubusercontent.com/SYNically-ACKward/se-lab-automation/main/standup.sh | bash standup.sh` and follow the subsequent menu prompts. 

The script options are intended to be executed in order as the components build on each other. For instance, the 'Deploy pfSense' option will reference SDN VNETs created by the 'Configure Networking' component. Improvements will be made in the future to abstract each of thsese components from one another. 

***

## Component - Configure Networking

Configure Networking will configure the SDN options within ProxMox VE. A single zone named 'lan' will be created that contains three VNETs - vnet1, vnet2, vnet3. Each of these VNETs will have a single associated subnet 10.X.0.0/24 with the 'X' matching the last digit of the VNET name. This component will also install dnsmasq on the ProxMox VE node and enable PVE-managed IPAM. DHCP ranges for .20-254 will be created for each subnet. 

***

## Component - Deploy pfSense

Deploy pfSense will pull a pfSense ISO from an S3 bucket (note that this will take some time) and will deploy a QEMU Virtual Machine with VMID 777 on the ProxMox VE node. The VM will have the following specifications by default with the user being prompted to adjust if necessary:

CPU: 2
Memory: 4096
Disk: 32Gb
NIC1: vmbr0
NIC2: vmbr0
NIC3: vnet1
NIC4: vnet2
NIC5: vnet3

> :warning: **Note**: After successfully running the 'Deploy pfSense' component the user will need to open the ProxMox webUI and go to the 'Console' tab for the VM and complete the installation of the pfSense OS in order to proceed to the next step of the automation script. This will be automated in the future. 

***

## Component - Apply pfSense Base Config

Apply pfSense Base Config will retrieve a config.xml file containing a very basic pfSense configuration from the code repository. This workflow will perform the initial interface configuration of the pfSense VM, SSH to the pfSense VM and apply the configuration file. It is important that no settings are modified by the user on the pfSense VM before running this component. The base credentials of the VM will be set to admin / zscaler. The WAN interface is mapped to NIC1, the MGMT interface is mapped to NIC2 and the LANX interfaces are mapped to the respective VNETs. The .1 gateway address for each VNET has been configured on the corresponding LAN interface. NAT policies have been configured for NO-NAT on the MGMT interface and to NAT the three LAN interfaces to the IP of the WAN interface. Security policy is set to allow all outbound traffic by default. 