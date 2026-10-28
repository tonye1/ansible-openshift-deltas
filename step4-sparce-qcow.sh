cd /var/lib/libvirt/images/ocpz

for img in *.qcow2; do
  echo "Sparsifying $img ..."
  virt-sparsify --in-place "$img"
done
