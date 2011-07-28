#!/usr/bin/env bash
OPENSTACK=$HOME/openstack
CONFDIR=$OPENSTACK/conf
OPENBIN=$OPENSTACK/bin

PATH=$OPENBIN:$PATH
export PATH

NOVA_DIR=$OPENSTACK/nova
GLANCE_DIR=$OPENSTACK/glance

XS_IP=${XS_IP:-127.0.0.1}
XS_USER=${XS_USER:-root}
XS_PASS=${XS_PASS:-qwerty}
USE_MYSQL=${USE_MYSQL:-1}
MYSQL_PASS=${MYSQL_PASS:-nova}
TEST=${TEST:-0}
LIBVIRT_TYPE=${LIBVIRT_TYPE:-qemu}
#NET_MAN=${NET_MAN:-VlanManager}
NET_MAN=${NET_MAN:-FlatManager}

if [[ "$USE_MYSQL" == 1 ]]; then
    SQL_CONN=mysql://root:$MYSQL_PASS@localhost
else
    SQL_CONN=sqlite:///$OPENSTACK/nova.sqlite
fi

function write_screenrc {
  if [[ -e $OPENSTACK/.screenrc ]]; then
      return
  fi
  echo "3-> writing $OPENSTACK/.screenrc"

  echo -n 'startup_message off
vbell off
defscrollback 10000
altscreen on

bind c screen 1
bind 0 select 10

screen -t "api" 1
stuff "clear\012"
stuff "$NOVA_DIR/bin/nova-api --flagfile=$CONFDIR/nova.conf\012"
screen -t "objectstore" 2
stuff "clear\012"
stuff "$NOVA_DIR/bin/nova-objectstore --flagfile=$CONFDIR/nova.conf\012"
screen -t "compute" 3
stuff "clear\012"
stuff "$NOVA_DIR/bin/nova-compute --flagfile=$CONFDIR/nova.conf\012"
screen -t "network" 4
stuff "clear\012"
stuff "$NOVA_DIR/bin/nova-network --flagfile=$CONFDIR/nova.conf\012"
screen -t "scheduler" 5
stuff "clear\012"
stuff "$NOVA_DIR/bin/nova-scheduler --flagfile=$CONFDIR/nova.conf\012"
screen -t "test" 6
stuff "clear\012"
stuff "sleep 3\012"
stuff ". $CONFDIR/novarc\012"
stuff "euca-add-keypair nova_key > $CONFDIR/nova_key.priv\012"
stuff "nova image-list\012"
stuff "nova flavor-list\012"
stuff "nova list\012"
stuff "nova boot t1 --flavor=1 --image="
screen -t "db" 9
stuff "clear\012"
stuff "mysql -uroot -pnova\012"
stuff "use nova\012"

caption always "%{= g}%-w%{= r}%n %t%{-}%+w %-=%{g}(%{d}%H/%l%{g})"

select 6' > $OPENSTACK/.screenrc
}

function branch {
    SOURCE_BRANCH=lp:nova
    DEST_DIR=nova-trunk
    LINK_DIR=$NOVA_DIR
    if [[ -n "$2" ]]; then
        SOURCE_BRANCH=$2
        if [[ $SOURCE_BRANCH == *glance* ]]; then
            LINK_DIR=$GLANCE_DIR
        fi
        if [[ $SOURCE_BRANCH == "lp:glance" ]]; then
            DEST_DIR=glance-trunk
        elif [[ -n "$3" ]]; then
            DEST_DIR=$3
        else
            DEST_DIR=$(echo $2 | cut -d: -f2)
            DEST_DIR=${DEST_DIR##*/}
        fi
    fi
    if [[ -d $OPENSTACK/$DEST_DIR ]]; then
        if [[ $(basename $OPENSTACK/$DEST_DIR) != $(basename $OPENSTACK) ]]
        then
            echo "$OPENSTACK/$DEST_DIR exists... removing"
            rm -rf $OPENSTACK/$DEST_DIR
        fi
    fi
    bzr branch $SOURCE_BRANCH $OPENSTACK/$DEST_DIR
    if [[ -e $LINK_DIR ]]; then
        rm $LINK_DIR
    fi
    ln -s `cd $OPENSTACK/$DEST_DIR; pwd` $LINK_DIR
}

function pull {
    PROJECT=nova
    if [[ -n "$2" ]]; then
        PROJECT=$2
    fi
    echo "bzr pull -d $OPENSTACK/$PROJECT"
    bzr pull -d $OPENSTACK/$PROJECT
}

# You should only have to run this once
function install {
    apt-get install -y bzr mysql-server build-essential rabbitmq-server euca2ools unzip
    apt-get install -y python-twisted python-gflags python-carrot python-eventlet python-ipy python-sqlalchemy python-mysqldb python-webob python-redis python-mox pyth
    apt-get install -y python-m2crypto python-netaddr python-pastedeploy python-migrate python-tempita iptables

    if [[ "$USE_MYSQL" == 1 ]]; then
        mysqladmin -u root -p $MYSQL_PASS password $MYSQL_PASS
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE nova;'
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE glance;'
    fi
}

function setup {
  if [[ ! -d "$OPENSTACK" ]]; then
      echo "3-> mkdir $OPENSTACK"
      mkdir -p $OPENSTACK
  fi
  if [[ ! -d $OPENSTACK/.bzr ]]; then
      bzr init $OPENSTACK
  fi
  if [[ ! -d "$CONFDIR" ]]; then
      echo "3-> mkdir $CONFDIR"
      mkdir -p $CONFDIR
  fi
  if [[ ! -d "$OPENBIN" ]]; then
      echo "3-> mkdir $OPENBIN"
      mkdir -p $OPENBIN
  fi
}

function setup_glance {
  if [[ ! -d "$CONFDIR/logs" ]]; then
    mkdir -p $CONFDIR/logs
  fi
  if [[ ! -d "$CONFDIR/image-cache" ]]; then
    mkdir -p $CONFDIR/image-cache
  fi
  if [[ ! -d "$CONFDIR/images" ]]; then
    mkdir -p $CONFDIR/images
  fi
  cp -a $GLANCE_DIR/etc/*.conf $CONFDIR
  # sed lets you use anything as the separators as long as it follows the
  # pattern
  sed -i "s:/var/log/glance:$CONFDIR/logs:" $CONFDIR/glance*.conf
  sed -i "s:/var/lib/glance:${CONFDIR}:" $CONFDIR/glance*.conf

  OLD_PWD=$(pwd)
  cd $GLANCE_DIR
  python setup.py develop --script-dir $OPENBIN
  cd $OLD_PWD

  sed -i "s_$OPENSTACK/.+/bin/_$OPENSTACK/glance/bin/_" $OPENBIN/glance*
  pip install -r $GLANCE_DIR/tools/pip-requires
}

function setup_nova {
  pip install -r $NOVA_DIR/tools/pip-requires
}

function upload_images {
  for image in $(ls $HOME/*.ova); do
      echo "3-> uploading $image"
      glance add name=$image is_public=True < $image
  done
}

function run {
  if [[ ! -d "$CONFDIR" ]]; then
    mkdir -p $CONFDIR
  fi
  echo "3-> writing $CONFDIR/nova.conf"
  sh -c "cat > $CONFDIR/nova.conf << EOF
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

    echo "3-> cleaning vlans"
    $NOVA_DIR/tools/clean-vlans

    glance-manage --config-file=$CONFDIR/glance-registry.conf --sql-connection=$SQL_CONN/glance db_sync
    glance-control api start $CONFDIR/glance-api.conf
    glance-control registry start $CONFDIR/glance-registry.conf

    if [[ $(glance index) == *No*image* ]]; then
        upload_images
    fi

    if [[ "$TEST" == 1 ]]; then
        echo "3-> running tests"
        cd $NOVA_DIR
        python $NOVA_DIR/run_tests.py
        cd $OPENSTACK
    fi

    # only create these if nova.zip doesn't exist
    # nova.zip is removed in the teardown phase
    # allows rerunning without issue and without teardown
    if [[ ! -f nova.zip ]]; then
        echo "3-> creating user, project, env_variables, and network"
        cd $NOVA_DIR/nova/CA

        ./genrootca.sh
        cd $OPENSTACK
        echo db sync
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf db sync
        # create an admin user called 'admin'
        echo user
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf user admin admin admin
        # create a project called 'admin' with project manager of 'admin'
        echo project
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf project create openstack admin

        echo networks
        $NOVA_DIR/bin/nova-manage --flagfile=$CONFDIR/nova.conf network create --label=public --fixed_range_v4=10.1.1.0/30 --num_networks=1 --network_size=4 --bridge=xenbr0

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
    export CONFDIR
    # nova api crashes if we start it with a regular screen command,
    # so send the start command by forcing text into the window.
    echo "3-> starting screen"
    screen -S nova -c $OPENSTACK/.screenrc
}

function clean {
    echo "3-> kill screen (if running)"
    screen -S nova -X quit
    echo "3-> removing .pids"
    glance-control all stop
}

function teardown {
    echo "3-> rm $CONFDIR/nova.zip"
    rm -f $CONFDIR/nova.zip

    echo "3-> resetting database"
    if [[ "$USE_MYSQL" == 1 ]]; then
        mysql -uroot -p$MYSQL_PASS -e 'DROP DATABASE nova;'
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE nova;'
        mysql -uroot -p$MYSQL_PASS -e 'DROP DATABASE glance;'
        mysql -uroot -p$MYSQL_PASS -e 'CREATE DATABASE glance;'
    else
        rm -f $DIR/nova.sqlite
    fi

    echo "3-> destroying xenserver instances"
    ssh root@$XS_IP /root/bin/clobber.sh
}

function die_in_a_fire {
    exit
}

trap die_in_a_fire SIGINT

case "$1" in
    branch)
        branch $@
        ;;

    clean)
        clean $@
        ;;

    teardown)
        teardown $@
        ;;

    install)
        install $@
        ;;

    setup)
        setup
        write_screenrc
        branch "" "lp:glance"
        setup_glance
        branch
        setup_nova
        ;;

    setup-glance)
        setup_glance
        ;;

    setup-nova)
        setup_nova
        ;;
    run)
        if [[ ! -d $OPENSTACK ]]; then
            $0 setup
        fi
        run $@
        ;;

    pull)
        pull $@
        ;;

    update)
        pull $@
        ;;

    reset)
        $0 clean $@ && $0 teardown $@
        ;;
esac
