#!/usr/bin/env bash
OPENSTACK=$HOME/openstack
SCREENRC=$HOME/screenrc-nova
CONFDIR=$OPENSTACK/conf

# $SUDO will blindly be prepended onto commands
SUDO_CMD=''
#SUDO_CMD='$SUDO_CMD'

CMD=$1

NOVA_DIR=$OPENSTACK/nova
GLANCE_DIR=$OPENSTACK/glance

if [ -n "$3" ]; then
    NOVA_DIR=$OPENSTACK/$3
fi


XS_IP=${XS_IP:-127.0.0.1}
XS_USER=${XS_USER:-root}
XS_PASS=${XS_PASS:-qwerty}
USE_MYSQL=${USE_MYSQL:-1}
MYSQL_PASS=${MYSQL_PASS:-nova}
TEST=${TEST:-0}
LIBVIRT_TYPE=${LIBVIRT_TYPE:-qemu}
#NET_MAN=${NET_MAN:-VlanManager}
NET_MAN=${NET_MAN:-FlatManager}
# NOTE(vish): If you are using FlatDHCP make sure that this is not your
#             public interface. You can comment it out for local usage
BRIDGE_DEV=eth0


if [ "$USE_MYSQL" == 1 ]; then
    SQL_CONN=mysql://root:$MYSQL_PASS@localhost
else
    SQL_CONN=sqlite:///$OPENSTACK/nova.sqlite
fi

if [ "$CMD" == "run" ]; then
  if [ ! -d "$CONFDIR" ]; then
    mkdir -p $CONFDIR
  fi
  echo "3-> writing $CONFDIR/nova.conf"
  $SUDO_CMD sh -c "cat > $CONFDIR/nova.conf << EOF
--verbose
--nodaemon
--sql_connection=$SQL_CONN/nova
--network_manager=nova.network.manager.$NET_MAN
--image_service=nova.image.glance.GlanceImageService
--connection_type=xenapi
--xenapi_connection_url=https://$XS_IP
--xenapi_connection_username=$XS_USER
--xenapi_connection_password=$XS_PASS
--rescue-timeout=86400
--allow_admin_api=true
--xenapi_inject_image=false
--xenapi_remap_vbd_dev=true
--flat_injected=false
--ca_path=$NOVA_DIR/nova/CA
EOF"
#--use_ipv6=true
#--flat_network_bridge=xenbr0
#--image_service=nova.image.local.LocalImageService
fi

function branch {
    SOURCE_BRANCH=lp:nova
    DEST_DIR=nova-trunk
    if [ -n "$2" ]; then
        SOURCE_BRANCH=$2
        if [ -n "$3"]; then
            DEST_DIR=$3
        else
            DEST_DIR=$(echo $2 | cut -d: -f2)
            DEST_DIR=${STR##*/}
        fi
    fi
    rm $NOVA_DIR
    bzr branch $SOURCE_BRANCH $DEST_DIR
    ln -s $NOVA_DIR `cd $OPENSTACK/$DEST_DIR; pwd`
    mkdir -p $NOVA_DIR/instances
    mkdir -p $NOVA_DIR/networks
}

# You should only have to run this once
function install {
    $SUDO_CMD apt-get install -y bzr mysql-server build-essential rabbitmq-server euca2ools unzip
    $SUDO_CMD apt-get install -y python-twisted python-gflags python-carrot python-eventlet python-ipy python-sqlalchemy python-mysqldb python-webob python-redis python-mox pyth
    $SUDO_CMD apt-get install -y python-m2crypto python-netaddr python-pastedeploy python-migrate python-tempita iptables

    if [ "$USE_MYSQL" == 1 ]; then
        mysqladmin -u root -p $MYSQL_PASS password $MYSQL_PASS
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE nova;'
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE glance;'
    fi
}

function run {
    echo "3-> resetting instances and networks folders"
    $SUDO_CMD rm -rf $NOVA_DIR/instances
    mkdir -p $NOVA_DIR/instances
    $SUDO_CMD rm -rf $NOVA_DIR/networks
    mkdir -p $NOVA_DIR/networks

    echo "3-> cleaning vlans"
    $SUDO_CMD $NOVA_DIR/tools/clean-vlans

#    echo "3-> making sure glance is up to date"
#    cd $GLANCE_DIR
#    bzr pull
#    $SUDO_CMD python setup.py install
    $SUDO_CMD glance-manage --config-file=$CONFDIR/glance-registry.conf --sql-connection=$SQL_CONN/glance db_sync


    if [ ! -d "$NOVA_DIR/images" ]; then
        ln -s $OPENSTACK/images $NOVA_DIR/images
    fi

    if [ "$TEST" == 1 ]; then
        echo "3-> running tests"
        cd $NOVA_DIR
        python $NOVA_DIR/run_tests.py
        cd $OPENSTACK
    fi

    # only create these if nova.zip doesn't exist
    # nova.zip is removed in the teardown phase
    # allows rerunning without issue and without teardown
    if [ ! -f nova.zip ]; then
        echo "3-> creating user, project, env_variables, and network"
        cd $NOVA_DIR/nova/CA

        $SUDO_CMD ./genrootca.sh
        cd $OPENSTACK
        echo db sync
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf db sync
        # create an admin user called 'admin'
        echo user
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf user admin admin admin
        # create a project called 'admin' with project manager of 'admin'
        echo project
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf project create openstack admin
        # export environment variables for project 'admin' and user 'admin'
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf project environment admin admin $NOVA_DIR/novarc
        # create a small network
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf network create 192.168.0.0/16 1 32 0 0 0 private
        # create a small network 2
        echo networks
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf network create --label=public --network=10.1.1.0/30 --num_networks=1 --network_size=4 --bridge_interface=xenbr0

        # create zip file
        cd $CONFDIR
        echo project zip
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf project zip openstack admin
        # extract/remove zip file
        echo unzip
        unzip -o nova.zip
    fi

    export NOVA_DIR
    export GLANCE_DIR
    export OPENSTACK
    export SUDO_CMD
    export CONFDIR
    # nova api crashes if we start it with a regular screen command,
    # so send the start command by forcing text into the window.
    echo "3-> starting screen"
    screen -S nova -c $SCREENRC
}

function clean {
    echo "3-> kill screen (if running)"
    screen -S nova -X quit
    echo "3-> removing .pids"
#    $SUDO_CMD killall /usr/bin/python
    $SUDO_CMD glance-control all stop
    $SUDO_CMD rm -f *.pid*
    $SUDO_CMD rm -f n3va.[0-9]*
}

function teardown {
    echo "3-> rm $CONFDIR/nova.zip"
    rm -f $CONFDIR/nova.zip

    echo "3-> resetting database"
    if [ "$USE_MYSQL" == 1 ]; then
        mysql -uroot -p$MYSQL_PASS -e 'DROP DATABASE nova;'
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE nova;'
#        mysql -uroot -p$MYSQL_PASS -e 'DROP DATABASE glance;'
#        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE glance;'
    else
        rm -f $DIR/nova.sqlite
    fi

    echo "3-> destroying xenserver instances"
    ssh root@$XS_IP /root/bin/clobber.sh
}

case "$1" in
    branch)
        branch
        ;;

    clean)
        clean
        ;;

    teardown)
        teardown
        ;;

    install)
        install
        ;;

    run)
        run
        ;;

    reset)
        $0 clean && $0 teardown
        ;;
easc
