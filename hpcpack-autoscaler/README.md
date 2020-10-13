# Auto-scaling HPC Pack

## Configuring the Autoscaler

### Creating the virtualenv

```bash
    # If Cyclecloud is installed on the current machine:
    # cp /opt/cycle_server/tools/cyclecloud_api*.whl .
    wget --no-check-certificate https://localhost/static/tools/cyclecloud_api-8.0.1-py2.py3-none-any.whl

    python3 -m venv ~/.virtualenvs/cyclecloud-hpcpack
    . ~/.virtualenvs/cyclecloud-hpcpack/bin/activate
    pip install -r ./dev-requirements.txt
    pip install ./cyclecloud_api-8.0.1-py2.py3-none-any.whl
    pip install ./cyclecloud-scalelib-0.1.1.tar.gz
    python setup.py build
```


## NodeGroup Configuration

### NodeArrays and NodeGroups 

By default, each CycleCloud NodeArray maps to a separate NodeGroup named after the NodeArray.  So, for example, nodes started in the "ComputeNodes" nodearray are added to the default "ComputeNodes" NodeGroup and nodes added to the "ondemandMPI" nodearray are added to the new "ondemandMPI" NodeGroup.


The default NodeGroups for a NodeArray may be over-ridden by setting the ``configuration.hpcpack.node_groups`` attribute on the node group to a comma-separated list of NodeGroup names.


### Configuring Spot vs On-Demand

In CycleCloud, a NodeArray may  configured to use Spot by setting the ``Interruptible`` flag and optionally setting a ``MaxPrice`` to limit the spot price.  If a NodeArray has the ``Interruptible`` flag set, then when the autoscaler creates an instance of the VM, it will be a spot instance.

A common autoscaling use-case across schedulers is scaling a mix of on-demand and spot VMs for a single workflow.   In the HPC Pack autoscaler, this implies that both the Spot and On-Demand VMs should be added to the same NodeGroup(s) since the workflow can use either type.

To configure a single NodeGroup with a mix of Spot and On-Demand this way, set the ``autoscaler.SlotType`` attribute to a common name, use the ``autoscaler.Priority`` attribute to select the order of preference for autoscaling, and optionally set the ``MaxCount`` node attribute to limit the number of VMs of the higher priority type to auto-start.

For example, the following cluster template snippet prefers to autoscale up to a max of 10 on-demand VMs to meet an SLA and then autoscale as many spot VMs as are allowed by quota as long as cost is low enough:

```ini

[cluster myHpcCluster]

  [[nodearray ondemandComputeNodes]]
  Extends = Base
  Interruptible = false
  MaxCount = 10

    [[[configuration hpcpack]]]
    node_groups = ComputeNodes

    [[[autoscaler]]]
    slot_type = ComputeNodes
    priority = 100

  [[nodearray spotComputeNodes]]
  Extends =  Base
  Interruptible = true
  MaxPrice = 2.00

    [[[configuration hpcpack]]]
    node_groups = ComputeNodes
    
    [[[autoscaler]]]
    slot_type = ComputeNodes
    priority = 50

```


#### A Note on Priority:

When setting the **autoscaler.priority** attribute on a NodeArray, a higher value indictates greater priority.   So if multiple NodeArrays match a resource request and more than one has capacity, the autoscaler will prefer to create VMs from the NodeArray with the greatest Priority value.

If multiple NodeArrays match the resource requirements and have equal priorities, then the order of selection is undefined.


### Configuring Shutdown Policy

By default, the HPC Pack autoscaler stops and deletes VMs when the corresponding nodes are autostopped.  

To improve scale-up rate, nodearrays may instead be configured to stop and *deallocate* the VMs when the nodes are autostopped using the CycleCloud [ShutdownPolicy](https://docs.microsoft.com/en-us/azure/cyclecloud/includes/api_operations#terminate-or-deallocate-cluster-nodes) node attribute.

However, since the disks for deallocated VMs are not deleted, they continue to incur some cost to the subscription.   As a result, a common goal is to maintain a certain number VMs in the deallocated state for fast restarts, but delete surplus VMs to reduce cost.   This can be achieved in a very similar manner to the solution for Spot vs. On-Demand (above).

To configure a single NodeGroup to maintain a maximum number of deallocated VMs (N) and delete any surplus autostarted VMs, simply create two nodearrays one with ``ShutdownPolicy = Deallocate`` and ``MaxCount = N``, and the  other with  ``ShutdownPolicy = Terminate`` (the default).  Then use the ``autoscaler.Priority`` attribute to create a preference for (re-)starting deallocated (or deallocatable) nodes first.

For example, the following cluster template snippet prefers to start or re-start to a max of 10 deallocatable VMs and then autoscale as many additional VMs as are allowed by quota and delete them during autostop:

```ini

[cluster myHpcCluster]

  [[nodearray computeNodes]]
  Extends =  Base

    [[[configuration hpcpack]]]
    node_groups = ComputeNodes

    [[[autoscaler]]]
    slot_type = ComputeNodes
    priority = 50

  [[nodearray deallocatableComputeNodes]]
  Extends = computeNodes
  ShutdownPolicy = Deallocate
  MaxCount = 10

    [[[configuration hpcpack]]]
    node_groups = ComputeNodes

    [[[autoscaler]]]
    slot_type = ComputeNodes
    priority = 100

```

