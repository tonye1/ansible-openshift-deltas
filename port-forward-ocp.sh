sudo ssh -J <USERat><REPLACE> \
    -L 443:<REPLACE>:443 \
    -L 6443:<bastion-host>:6443 \
    -L 80:<REPLACE>:80 \
    <USERat><bastion-host> -N
