#!/usr/bin/env bash
OPENSTACK=$HOME/openstack
SCREENRC=$HOME/screenrc-nova
XS_IP=10.127.5.119

# $SUDO will blindly be prepended onto commands
SUDO_CMD=''
#SUDO_CMD='sudo'

CMD=$1
SOURCE_BRANCH=lp:nova
if [ -n "$2" ]; then
    SOURCE_BRANCH=$2
fi

NOVA_DIR=$OPENSTACK/nova
GLANCE_DIR=$OPENSTACK/glance

if [ -n "$3" ]; then
    NOVA_DIR=$OPENSTACK/$3
fi

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
  echo "3-> writing $OPENSTACK/nova.conf"
  sudo sh -c "cat > $OPENSTACK/nova.conf << EOF
--verbose
--nodaemon
--sql_connection=$SQL_CONN/nova
--network_manager=nova.network.manager.$NET_MAN
--image_service=nova.image.glance.GlanceImageService
--connection_type=xenapi
--xenapi_connection_url=https://$XS_IP
--xenapi_connection_username=root
--xenapi_connection_password=qwerty
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

if [ "$CMD" == "branch" ]; then
    rm -rf $NOVA_DIR
    bzr branch $SOURCE_BRANCH $NOVA_DIR
    cd $NOVA_DIR
    mkdir -p $NOVA_DIR/instances
    mkdir -p $NOVA_DIR/networks
fi

# You should only have to run this once
if [ "$CMD" == "install" ]; then
    sudo apt-get install -y bzr mysql-server build-essential rabbitmq-server euca2ools unzip
    sudo apt-get install -y python-twisted python-gflags python-carrot python-eventlet python-ipy python-sqlalchemy python-mysqldb python-webob python-redis python-mox pyth
    sudo apt-get install -y python-m2crypto python-netaddr python-pastedeploy python-migrate python-tempita iptables

    if [ "$USE_MYSQL" == 1 ]; then
        mysqladmin -u root -p $MYSQL_PASS password $MYSQL_PASS
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE nova;'
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE glance;'
    fi
fi

if [ "$CMD" == "run" ]; then
    echo "3-> resetting instances and networks folders"
    sudo rm -rf $NOVA_DIR/instances
    mkdir -p $NOVA_DIR/instances
    sudo rm -rf $NOVA_DIR/networks
    mkdir -p $NOVA_DIR/networks

    echo "3-> cleaning vlans"
    sudo $NOVA_DIR/tools/clean-vlans

#    echo "3-> making sure glance is up to date"
#    cd $GLANCE_DIR
#    bzr pull
#    sudo python setup.py install
    sudo glance-manage --sql-connection=$SQL_CONN/glance db_sync


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

        sudo ./genrootca.sh
        cd $OPENSTACK
        echo db sync
        $NOVA_DIR/bin/nova-manage --flagfile=$OPENSTACK/nova.conf db sync
        # create an admin user called 'admin'
        echo user
        $NOVA_DIR/bin/nova-manage --flagfile=$OPENSTACK/nova.conf user admin admin admin
        # create a project called 'admin' with project manager of 'admin'
        echo project
        $NOVA_DIR/bin/nova-manage --flagfile=$OPENSTACK/nova.conf project create openstack admin
        # export environment variables for project 'admin' and user 'admin'
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf project environment admin admin $NOVA_DIR/novarc
        # create a small network
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf network create 192.168.0.0/16 1 32 0 0 0 private
        # create a small network 2
        echo networks
        $NOVA_DIR/bin/nova-manage --flagfile=$OPENSTACK/nova.conf network create public 10.1.1.0/30 1 4 0 0 0 0 xenbr1
        $NOVA_DIR/bin/nova-manage --flagfile=$OPENSTACK/nova.conf network create public 10.10.1.0/30 1 4 0 0 0 0 xenbr1
        $NOVA_DIR/bin/nova-manage --flagfile=$OPENSTACK/nova.conf network create private 10.2.0.0/16 1 8 0 0 0 0 xenbr2
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf network create public 0 xenbr1
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf network create private 0 xenbr2
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf subnet create 1 10.1.1.0/24
#        $NOVA_DIR/bin/nova-manage --flagfile=nova.conf subnet create 2 10.2.0.0/24

        # create zip file
        echo project zip
        $NOVA_DIR/bin/nova-manage --flagfile=$OPENSTACK/nova.conf project zip openstack admin
        # extract/remove zip file
        echo unzip
        unzip -o nova.zip
    fi

    export NOVA_DIR
    export GLANCE_DIR
    export OPENSTACK
    export SUDO_CMD
    # nova api crashes if we start it with a regular screen command,
    # so send the start command by forcing text into the window.
    echo "3-> starting screen"
    screen -S nova -c $SCREENRC
fi

if [ "$CMD" == "clean" ]; then
    echo "3-> kill screen (if running)"
    screen -S nova -X quit
    echo "3-> removing .pids"
#    sudo killall /usr/bin/python
    sudo glance-control all stop
    sudo rm -f *.pid*
    sudo rm -f n3va.[0-9]*
fi

if [ "$CMD" == "teardown" ]; then
    echo "3-> rm nova.zip"
    rm -f nova.zip

    echo "3-> resetting database"
    if [ "$USE_MYSQL" == 1 ]; then
        mysql -uroot -p$MYSQL_PASS -e 'DROP DATABASE nova;'
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE nova;'
    else
        rm -f $DIR/nova.sqlite
    fi

    echo "3-> destroying xenserver instances"
    ssh root@$XS_IP /root/clobber.sh
fi
