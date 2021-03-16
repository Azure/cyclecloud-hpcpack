# Azure CycleCloud HPC Pack project

HPC Pack is Microsoft's free HPC solution built on Microsoft Azure and Windows Server technologies and supports a wide range of HPC workloads. For more information see [Microsoft HPC Pack overview](https://docs.microsoft.com/powershell/high-performance-computing/overview). This project supports HPC Pack 2016 (with Update 3) and HPC Pack 2019.

---

## Prerequisites

### Active directory domain

All HPC Pack nodes must be joined into an Active Directory Domain, if you don't have an AD domain yet in your virtual network, you can choose to create a new AD domain by promoting the head node as domain controller.

### Azure Key Vault Certificate and Secret

HPC Pack cluster requires a certificate to secure the node communication. While you can directly specify a PFX file and protection password in the template, we recommend that you [create (or import) an Azure Key Vault certificate](https://docs.microsoft.com/powershell/high-performance-computing/deploy-an-hpc-pack-cluster-in-azure#create-azure-key-vault-certificate-on-azure-portal). You can also create an secret in the same Azure Key Vault to pass your user password securely.

### Azure User Assigned Managed Identity

If you decide to use Azure Key Vault to pass the certificate and user password, you need to create an Azure User Assigned Managed Identity, and grant it the 'Get' permission for both Secret and Certificate of the Azure Key Vault. The HPC Pack nodes will use this identity to fetch the certificate and user password from the Azure Key Vault.

## Node Roles

There are three node roles in this template, head node, broker nodes and compute nodes.

- Head node: This template creates one head node with local databases.
- Broker nodes: The "broker" node array is used to create HPC Pack broker nodes, if you want to run SOA workload, you can create one or more broker nodes in it.
- Compute nodes: The "cn" node array is used to create HPC Pack compute nodes.


## Autoscale

You can enable autoscale for the cluster. The cluster is started only with the head node, when you submit jobs to the cluster, compute nodes will be created.
There are two scale down options: Deallocate or Terminate.
If you choose 'Deallocate' option, the compute node virtual machines will be deallocated on scale down, and the compute nodes will be taken offline and shown unreachable in HPC Pack cluster.
If you choose 'Terminate' option, the compute node virtual machines will be removed on scale down, and the compute nodes will also be removed in HPC Pack cluster.
