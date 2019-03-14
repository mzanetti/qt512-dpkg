#!/bin/bash


USERNAME=`id --user --name`
GROUPNAME=$USERNAME
USERID=150000
GROUPID=150000
USERDIR=/home/$USERNAME

MOUNTED_DIRECTORY=$PWD
MOUNT_POINT=$USERDIR/$PACKAGE

SOURCE_PATH_LOCAL=$MOUNTED_DIRECTORY
SOURCE_PATH_CONTAINER=$MOUNT_POINT

PARALLEL_BUILD=$((`nproc` + 1))
if [ -z "$DEB_BUILD_PROFILES" ]; then
    DEB_BUILD_PROFILES='nocheck nodoc'
fi

TARGET_ARCH=$(dpkg-architecture -qDEB_BUILD_ARCH)
HOST_FARCH=$(dpkg-architecture -f -a$TARGET_ARCH -qDEB_BUILD_MULTIARCH)
TARGET_FARCH=$(dpkg-architecture -f -a$TARGET_ARCH -qDEB_HOST_MULTIARCH)

SRC_TARBALL_URL="https://downloads.nymea.io/source/qt/"

PACKAGELIST="qt512base qt512xmlpatterns qt512declarative qt512connectivity"
QT_VERSION="5.12.1"

DISTRO="bionic"
LXD_IMAGE="ubuntu:${DISTRO}"
LXD_CONTAINER="qt-512-${DISTRO}-${TARGET_ARCH}"


########################################################################



BASH_GREEN="\e[1;32m"
BASH_ORANGE="\e[33m"
BASH_RED="\e[1;31m"
BASH_NORMAL="\e[0m"

printGreen() {
    if ${COLORS}; then
        echo -e "${BASH_GREEN}[+] $1${BASH_NORMAL}"
    else
        echo -e "[+] $1"
    fi
}

printOrange() {
    if ${COLORS}; then
        echo -e "${BASH_ORANGE}[-] $1${BASH_NORMAL}"
    else
        echo -e "[-] $1"
    fi
}

printRed() {
    if ${COLORS}; then
        echo -e "${BASH_RED}[!] $1${BASH_NORMAL}"
    else
        echo -e "[!] $1"
    fi
}

new_container () {
    # setup the building container
    if lxc info $LXD_CONTAINER > /dev/null 2>&1 ; then
        printGreen "LXD container $LXD_CONTAINER already exists."
        # FIXME: check if the container is already started
        lxc start $LXD_CONTAINER || true
    else
        printGreen "Creating LXD container $LXD_CONTAINER using $LXD_IMAGE"
        lxc remote --public=true --accept-certificate=true add nymea https://jenkins.nymea.io || true
#        lxc remote --protocol=simplestreams --public=true --accept-certificate=true add sdk https://sdk-images.canonical.com || true
        lxc init $LXD_IMAGE $LXD_CONTAINER
        if [ -n "$ENCRYPTED_HOME" ] ; then
            lxc config set $LXD_CONTAINER security.privileged true
        else
            # Note: check the lxc version for lxc.id_map vs lxc.idmap
            LXCVERSION=$(lxc --version)
            LXCMAJORVERSION=$(echo ${LXCVERSION} | cut -d. -f1)
            if [ "${LXCMAJORVERSION}" -lt "3" ]; then
                printGren "Using lxc version 2 compatibility$LXD_IMAGE."
                printf "lxc.id_map = g $GROUPID `id --group` 1\nlxc.id_map = u $USERID `id --user` 1" | lxc config set $LXD_CONTAINER raw.lxc -
            else
                printf "lxc.idmap = g $GROUPID `id --group` 1\nlxc.idmap = u $USERID `id --user` 1" | lxc config set $LXD_CONTAINER raw.lxc -
            fi
        fi

        lxc start $LXD_CONTAINER
        lxc exec --env GROUPID=$GROUPID --env GROUPNAME=$GROUPNAME $LXD_CONTAINER -- addgroup --gid $GROUPID $GROUPNAME
        lxc exec --env GROUPID=$GROUPID --env USERNAME=$USERNAME --env USERID=$USERID $LXD_CONTAINER -- adduser --disabled-password --gecos "" --uid $USERID --gid $GROUPID $USERNAME
        lxc exec --env USERNAME=$USERNAME $LXD_CONTAINER -- usermod -aG sudo $USERNAME
        exec_container_root "sed -i 's/ENV_PATH.*PATH=/ENV_PATH\tPATH=\/usr\/lib\/ccache:/' /etc/login.defs"
        # wait for the container's network connection
        check_for_container_network
        check_for_dpkg_available
        exec_container_root apt update
        exec_container_root apt install -y sudo debhelper ccache software-properties-common devscripts equivs
        exec_container_root adduser $USERNAME sudo
        # set empty password for the user
        exec_container_root passwd --delete $USERNAME
    fi

    if ! lxc config device get $LXD_CONTAINER current_dir_mount disk 2> /dev/null ; then
        printGreen "Mounting $MOUNTED_DIRECTORY in container."
        lxc config device add $LXD_CONTAINER current_dir_mount disk source=$MOUNTED_DIRECTORY path=$MOUNT_POINT
    else
        lxc config device set $LXD_CONTAINER current_dir_mount source $MOUNTED_DIRECTORY
    fi

   if ! lxc config device get $LXD_CONTAINER ccache_dir_mount disk 2> /dev/null ; then
       printGreen "Mounting ccache dir ($HOME/.ccache) in container."
       lxc config device add $LXD_CONTAINER ccache_dir_mount disk source=$HOME/.ccache/ path=$HOME/.ccache
   fi

}

shell_container () {
    echo "${POSITIVE_COLOR}Entering shell in LXD container $LXD_CONTAINER.${NC}"
    lxc exec $LXD_CONTAINER -- su --login $USERNAME
}

exec_container_root () {
    command="$@"
    #echo lxc exec $LXD_CONTAINER "$@"
    lxc exec $LXD_CONTAINER -- sh -c "$command"
}

exec_container () {
    command="$@"
    #echo lxc exec $LXD_CONTAINER "$@"
    lxc exec $LXD_CONTAINER -- su -l -c "cd $SOURCE_PATH_CONTAINER; $command" $USERNAME
}

delete_container () {
    printOrange "Deleting LXD container $LXD_CONTAINER."
    lxc delete -f $LXD_CONTAINER
}

check_for_container_network() {
    NETWORK_UP=0
    for i in `seq 1 20`
    do
        if lxc info $LXD_CONTAINER | grep -e "eth0.*inet\b" > /dev/null 2>&1 ; then
            NETWORK_UP=1
            break
        fi
        sleep 1
    done
    if [ $NETWORK_UP -ne 1 ] ; then
        echo "${ERROR_COLOR}Container is not connected to the Internet.${NC}"
        exit 1
    fi
}
check_for_container_network() {
    NETWORK_UP=0
    for i in `seq 1 20`
    do
        if lxc info $LXD_CONTAINER | grep -e "eth0.*inet\b" > /dev/null 2>&1 ; then
            NETWORK_UP=1
            break
        fi
        sleep 1
    done
    if [ $NETWORK_UP -ne 1 ] ; then
        echo "${ERROR_COLOR}Container is not connected to the Internet.${NC}"
        exit 1
    fi
}

check_for_dpkg_available() {
    DPKG_AVAILABLE=0
    for i in `seq 1 60`
    do
        if exec_container_root test ! -e /var/lib/dpkg/lock; then
            DPKG_AVAILABLE=1
            echo ""
            break
        fi
        if [ $i -eq 1 ]; then
            printOrange "/var/lib/dpkg/lock exists..."
            echo -n "Waiting for it to disappear..."
        else
            echo -n "."
        fi
        sleep 1
    done
    if [ $DPKG_AVAILABLE -ne 1 ] ; then
        echo ""
        printOrange "/var/lib/dpkg/lock still exists after one minute. Assuming it is stale. Deleting it..."
        exec_container_root rm /var/lib/dpkg/lock
    fi
}

install_dependencies() {
    exec_container "cd $1; mk-build-deps -a $TARGET_ARCH"
    exec_container_root "cd $SOURCE_PATH_CONTAINER/builddir; dpkg -i *.deb || apt-get --yes -f install"
    exec_container_root "cd $SOURCE_PATH_CONTAINER/$1; dpkg -i *.deb || apt-get --yes -f install"
}

build() {
    for PACKAGENAME in $PACKAGELIST; do
        VERSIONED_PACKAGENAME=${PACKAGENAME}_${QT_VERSION}
        TARBALL_SRC=${PACKAGENAME}_${QT_VERSION}.orig.tar.xz
        if [ -e $TARBALL_SRC ]; then
            printGreen "$TARBALL_SRC already downloaded. Skipping dowload."
        else
            wget $SRC_TARBALL_URL/$TARBALL_SRC
        fi

        OUT_DIR=builddir/${PACKAGENAME}_${QT_VERSION}
        mkdir -p $OUT_DIR

        printGreen "Extracting $TARBALL_SRC to $OUT_DIR"
        tar xf $TARBALL_SRC --strip=1 -C $OUT_DIR

        echo "Copying $VERSIONED_PACKAGENAME/debian to $OUT_DIR"
        cp -r $VERSIONED_PACKAGENAME/debian/ $OUT_DIR

        install_dependencies $OUT_DIR
        exec_container "cd $OUT_DIR; DEB_BUILD_PROFILES='$DEB_BUILD_PROFILES' DEB_BUILD_OPTIONS='parallel=$PARALLEL_BUILD $DEB_BUILD_PROFILES' dpkg-buildpackage --target-arch $TARGET_ARCH -us -uc -nc -I -Iobj-* -Idebian/tmp/* -I.bzr* -b"
    done
}

clean() {
    for i in `ls *.tar.xz`; do
        printOrange "Deleting $i"
        rm $i
    done
    printOrange "Deleting builddir"
    rm -rf builddir
}

COMMAND=$1
if [ -n "$COMMAND" ] ; then
    shift
fi

#if [ $1 != "" ]; then
#    PACKAGELIST="$@"
#fi

if [ -z "$COMMAND" ] ; then
    #delete_container
    new_container
    build
else
    PARAMETERS=$@
    case "$COMMAND" in
        delete)
            delete_container
            ;;
        shell)
            shell_container
            ;;
        build)
            build
            ;;
        clean)
            clean
            ;;
    esac
fi
