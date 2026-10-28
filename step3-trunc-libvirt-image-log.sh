truncate -s 0 /var/log/libvirt/qemu/*.log
journalctl --vacuum-size=500M
dnf clean all
