# HPC Pack 2016 Update 1 for CycleCloud

---
## Features

This cluster launches a bastion host (for secure connection to the vnet), an
AD domain controller and an HPC Pack head node.  As jobs are submitted to the
head node, compute nodes with autoscale as needed.

### Prerequisites & Setup

CycleCloud can now simultaneously orchestrate environments described in ARM 
templates.  This feature requires version 7.x release of CycleCloud.

This project relies on the [HPC Pack github](https://github.com/Azure/hpcpack-template-2016)
in particular the DSC resources.  Project setup to download dependencies
are [scripted](setup_project.sh).

A certificate for internal cluster communication is also [included](hpcpack/blobs/hpc-comm.pfx)
and the certificate file password is the template default.  The certificate was
created with the additional included [script](setup_cert.ps1) if you wish to
create your own.

Once the project script has been executed you're ready to upload the project 
to the configuration locker, import the cluster, and make cluster edits in the UI.

    cyclecloud project_upload
    cyclecloud import_cluster HPCPack -c hpcpack -f hpcpack/templates/hpcpack_with_ad.txt

