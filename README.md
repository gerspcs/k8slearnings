# pik8slearnings
learning experience from a very helpful open community - the hacks along the way

Steps - what I did based on the following references
Web sites that really helped

https://kubecloud.io/setting-up-a-kubernetes-1-11-raspberry-pi-cluster-using-kubeadm-952bbda329c8

https://kubecloud.io/kubernetes-dashboard-on-arm-with-rbac-61309310a640

https://blog.hypriot.com/post/setup-kubernetes-raspberry-pi-cluster/

1. Download the image and unzip
unzip 2018-06-27-raspbian-stretch-lite.zip

2. Flash a memory card with the OS image

option 1
Linux cli
lsblk   - identify sdk card
umount /media/user/whatever - unmount disk
sudo dd if=imagefile.img of=/dev/sdkcard  bs=1M

option2
Etcher  - install version 1.4.6 - check out the web site https://www.balena.io/etcher/
unzip etcher-electron-1.4.6-linux-ia32.zip
./etcher-electron-1.4.6-i386.AppImage
echo "deb https://deb.etcher.io stable etcher" | sudo tee /etc/apt/sources.list.d/etcher.list
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys WHATEVER-THE-KEY-DETAIL-IS
sudo apt-get update
sudo apt-get install etcher-electron
etcher

3. On the installed OS sdk - enable ssh
sudo touch boot/ssh

THIS IS WIP
