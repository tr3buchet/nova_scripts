#!/bin/bash
echo 'This will destroy and clean up all Slices on a XenServer Host'

if [ -n $1 ]; then
    ARG=$1
fi

# change field separator to endline instead of ' '
IFS=`echo -en "\n\b"`

# ignored name-labels
ignored=( "Control domain on host: 127-5-118-127-5-118" compute )

function exists {
    if [ -z $1 ]; then
        return
    fi

    for i in ${ignored[@]}; do
        if [ $i == $1 ]; then
            return 1
        fi
    done

    return 0
}

function get_uuid {
    if [ -z $1 ]; then
        return
    fi

    local uuid=`xe vm-list params=uuid name-label="$1" | tr -s '\n' | sed 's|.* ||'`
    echo "$uuid"
}

function shutdown_uninstall {
    if [ -z $1 ]; then
        return
    fi

    local uuid=`get_uuid "$1"`

    if exists $1 != 1; then
        echo "shutting down |$1| -> |$uuid|"
        xe vm-shutdown --force uuid=$uuid 2>/dev/null
        xe vm-uninstall --force uuid=$uuid
    fi
}

for i in `xe vm-list params=name-label | tr -s '\n' | sed 's|[^:]*: ||' | sort`; do shutdown_uninstall $i; done
rm -rf /mnt/*

if [ "$ARG" == "WIPE" ]; then
    SR=`xe sr-list name-label=slices --minimal`
    rm -rf /var/run/sr-mount/$SR/*.vhd
fi
