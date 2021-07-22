# Azure CycleCloud HPC Pack project

HPC Pack is Microsoft's free HPC solution built on Microsoft Azure and Windows Server technologies and supports a wide range of HPC workloads. For more information see [Microsoft HPC Pack overview](https://docs.microsoft.com/powershell/high-performance-computing/overview). 

## Versions and Limitations

This project supports HPC Pack 2016 (with Update 3) and HPC Pack 2019.

Currently, the HPC Pack head node _must_ use the official Microsoft HPC Pack 2016 or 2019 Head Node images. Compute nodes may use custom images as usual for CycleCloud clusters.

Currently, only Windows Compute Nodes are supported.

Finally, the HPC Pack cluster type currently requires outbound internet access.  It uses that access to the [Nuget binary](https://aka.ms/nugetclidl), to download and install Python3  on the Head Node, and to reach PyPI to create an appropriate virtual environment for the CLI.

# Azure Subscription Requirements

Running an HPC Pack cluster requires some additional preparation in your Azure Subscription.

### Active directory domain

All HPC Pack nodes must be joined into an Active Directory Domain, if you don't have an AD domain yet in your virtual network, you can choose to create a new AD domain by promoting the head node as domain controller.

### Azure Key Vault Certificate and Secrets

HPC Pack cluster requires a certificate to secure the node communication. While you can directly specify a PFX file and protection password in the template, we recommend that you [create (or import) an Azure Key Vault certificate](https://docs.microsoft.com/powershell/high-performance-computing/deploy-an-hpc-pack-cluster-in-azure#create-azure-key-vault-certificate-on-azure-portal). You can also create an secret in the same Azure Key Vault to pass your user password securely.

The cluster also requires the Username and Password of an AD Administrator account to join nodes to the domain as they are created.   We strongly recommend passing the AD Admin username and password via Key Vault as well.

### Azure User Assigned Managed Identity

If you decide to use Azure Key Vault to pass the certificate and user password, you need to create an Azure User Assigned Managed Identity, and grant it the 'Get' permission for both Secret and Certificate of the Azure Key Vault. The HPC Pack nodes will use this identity to fetch the certificate and user password from the Azure Key Vault.

You can follow the instruction in the [Key Vault documentation](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/tutorial-windows-vm-access-nonaad) to create your Key Vault and a Managed Identity with Key Vault access.

We recommend using [Azure Role-Based Access Control](https://docs.microsoft.com/azure/key-vault/general/rbac-guide?tabs=azure-cli) to assign Key Vault permissions to the Managed Identity.

# Node Roles

There are three node roles in this template, head node, broker nodes and compute nodes.

- Head node: This template creates one head node with local databases.
- Broker nodes: The "broker" node array is used to create HPC Pack broker nodes, if you want to run SOA workload, you can create one or more broker nodes in it.
- Compute nodes: The "cn" node array is used to create HPC Pack compute nodes.

# Autoscale

You can enable autoscale for the cluster. The cluster is started only with the head node, when you submit jobs to the cluster, compute nodes will be created.
There are two scale down options for HPC Pack Compute Nodes: Deallocate or Terminate.
If you choose 'Deallocate' option, the compute node virtual machines will be deallocated on scale down, and the compute nodes will be taken offline and shown unreachable in HPC Pack cluster.

* If the ShutdownPolicy is set to Deallocate, the HPC Pack cluster will maintain the `deallocated` VMs for up to a configurable number of days (set using the `VMRetentionDays` cluster parameter.)

If you choose 'Terminate' option, the compute node virtual machines will be removed on scale down, and the compute nodes will also be removed in HPC Pack cluster.

By default, the autoscaler runs every minute as a Windows Scheduled Task on the Head Node of the cluster.

### azhpcpack cli

The `azhpcpack.ps1` cli is the main interface for all autoscaling behavior (the Scheduled Task calls `azhpcpack.ps1 autoscale`).  The CLI is available in `c:\cycle\hpcpack-autoscaler\bin\`.)

The CLI can be used to diagnose issues with autoscaling or to manually control cluster scaling from inside the Head Node.

| Command | Description |
| :---    | :---        |
| autoscale            | End-to-end autoscale process, including creation, deletion and joining of nodes. |
| buckets              | Prints out autoscale bucket information, like limits etc |
| config               | Writes the effective autoscale config, after any preprocessing, to stdout |
| create_nodes         | Create a set of nodes given various constraints. A CLI version of the nodemanager interface. |
| default_output_columns | Output what are the default output columns for an optional command. |
| delete_nodes         | Deletes node, including draining post delete handling |
| initconfig           | Creates an initial autoscale config. Writes to stdout |
| limits               | Writes a detailed set of limits for each bucket. Defaults to json due to number of fields. |
| nodes                | Query nodes |
| refresh_autocomplete | Refreshes local autocomplete information for cluster specific resources and nodes. |
| retry_failed_nodes   | Retries all nodes in a failed state. |
| validate_constraint  | Validates then outputs as json one or more constraints. |

# Known Issues

1. During initial cluster configuration, all Nodes must reboot at least once to join the AD Domain.  
   CycleCloud records the reboot as a possible configuration failure and nodes may temporarily display
   "Error configuring software" in the `Last Status Message` column of the Node table.  The reported error
   in the Issues or Node details will look like this:

   ```
   Unknown configuration status returned: 'rebooting'
   ```

   This error may be safely ignored.  
   The cluster nodes should automatically retry and succeed after the reboot.

# Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., label, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.
