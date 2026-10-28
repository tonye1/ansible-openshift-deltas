for vm in bootstrap control-0 control-1 control-2 compute-0 compute-1 compute-2; do
  virsh resume "$vm"
done
