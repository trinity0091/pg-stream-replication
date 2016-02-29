#!/bin/bash

# Defaults values
# Platforms: supported Nix* and Mac OS X. OS Windows is evil.
platform='unknown'
# User, under wich will be replication processed
user="postgres"
# Dir where init server cluster
data_dir="/var/lib/pgsql/data"
# Dir where will be stored pg_xlogs
wal_dir="/var/lib/pgsql/backups"
# Configug of PostgreSQL server
postgresql_conf="/var/lib/pgsql/data/postgresql.conf"
# ph_hba config path
pg_hba_conf="/var/lib/pgsql/data/pg_hba.conf"

function print_license {
echo -e "
+-------------------------------------------------------------------+
| This script setup master server of PostgreSQL and                 | 
| add them many slave servers.                                      |
| Copyright 2016 iSergio (s.serge.b@gmail.com).                     |
| Licensed under the Apache License, Version 2.0 (the \"License\");   |
| you may not use this file except in compliance with the License.  |
| You may obtain a copy of the License at                           |
| http://www.apache.org/licenses/LICENSE-2.0                        |
+-------------------------------------------------------------------+"
}
        
# Configure replication user name
# Need add checks for this user (master, slave ?)
function configure_user {
    echo -n "Please, enter username which will be used for replication(Default: postgres): "
    read _user
    if [[ -z $_user ]]; then
        _user=$user
    fi
    user=$_user
}

# Permanent configure master server
function configure_master {
    printf "+-----------------------------+\n"
    printf "|   Configure Master Server   |\n"
    printf "+-----------------------------+\n"
    echo -n "Please, enter path for postgresql.conf (Default: $postgresql_conf):"
    read _postgresql_conf
    if [[ -z $_postgresql_conf ]]; then
        _postgresql_conf=$postgresql_conf
    fi
    while [[ ! -f $_postgresql_conf ]]; do
        printf "Configuration file $_postgresql_conf not exists!\n"
        echo -n "Please, enter path for postgresql.conf (Default: $postgresql_conf):"
        read _postgresql_conf
        if [[ -z $_postgresql_conf ]]; then
            _postgresql_conf=$postgresql_conf
        fi
    done
    postgresql_conf=$_postgresql_conf

    echo -n "Please, enter path for pg_hba.conf (Default: $pg_hba_conf):"
    read _pg_hba_conf
    if [[ -z $_pg_hba_conf ]]; then
        _pg_hba_conf=$pg_hba_conf
    fi
    pg_hba_conf=$_pg_hba_conf

    printf "For configure master server will be used $postgresql_conf and $pg_hba_conf file.\n"

    archive_command="scp %p"
    for ((i = 0; i < ${#slave_hosts[@]}; i++)); do
        archive_command="$archive_command ${slave_hosts[$i]}:$wal_dir/%f"
    done
    cat <<EOF >> $postgresql_conf
# Stream replication generated by script 
# postgresql-stream-replecation.sh
# Written by iSergio s.serge.b@gmail.com
# BEGIN
listen_addresses='*'
wal_level = hot_standby
max_wal_senders = 5
wal_keep_segments = 32
archive_mode = on
archive_command = '$archive_command'
EOF
    # Fix for VNIINS MCBC5
    if grep -q "vniins_mac_mode" "$postgresql_conf"; then
        cat <<EOF >> $postgresql_conf

vniins_mac_mode = compat_linter7
EOF
    fi
    cat <<EOF >> $postgresql_conf
# END
EOF
if type "pgtune" > /dev/null  2>&1; then
    pgtune -i $postgresql_conf -o $postgresql_conf -T DW -c 200
fi
cat <<EOF >> $pg_hba_conf
# Stream replication generated by script 
# postgresql-stream-replecation.sh
# Written by iSergio s.serge.b@gmail.com
# BEGIN
EOF
    cat <<EOF >> $pg_hba_conf
host    replication     postgres    ${master_hosts[$host_n]}/32     trust
EOF
    for ((i = 0; i < ${#slave_hosts[@]}; i++)); do
        cat <<EOF >> $pg_hba_conf
host    replication     postgres    ${slave_hosts[$i]}/32       trust
EOF
    done
cat <<EOF >> $pg_hba_conf
#END
EOF
    read -r -p "Restart PostgreSQL server? [y/N]" response
    if [[ $response =~ ^([yY][eE][sS]|[yY])$ ]]; then
        service postgresql restart
    fi
}

function configure_slave {
    printf "+-----------------------------+\n"
    printf "|   Configure Slave Server    |\n"
    printf "+-----------------------------+\n"
    echo -n "Please, enter slave server host: "
    read slave_host
    echo -n "Please, enter path postgresql.conf (Default: $postgresql_conf):"
    _postgresql_conf=""
    read _postgresql_conf
    if [[ -z $_postgresql_conf ]]; then
        _postgresql_conf=$postgresql_conf
    fi
    echo -n "Please, enter path for pg_hba.conf (Default: $pg_hba_conf):"
    read _pg_hba_conf
    if [[ -z $_pg_hba_conf ]]; then
        _pg_hba_conf=$pg_hba_conf
    fi
    echo -n "Please, enter path for DATADIR (Default: $data_dir):"
    _data_dir=""
    read _data_dir
    if [[ -z $_data_dir ]]; then
        _data_dir=$data_dir
    fi
    # Store info by slave
    slave_hosts[${#slave_hosts[@]}]=$slave_host
    slave_postgresql_confs[${#slave_hosts[@]} - 1]=$_postgresql_conf
    slave_data_dirs[${#slave_hosts[@]} - 1]=$_data_dir
    slave_pg_hba_confs[${#slave_hosts[@]} - 1]=$_pg_hba_conf

    echo "Copy public rsa key to "
    sudo -u $user cat `su $user -c 'echo $HOME'`/.ssh/id_rsa.pub | ssh $user@$slave_host 'mkdir -p .ssh && cat >> .ssh/authorized_keys'
    printf "Copy public rsa key from $slave_host to ${master_hosts[$host_n]}\n"
    sudo -u $user | ssh $user@$slave_host 'ssh-keygen -t rsa -P "" -f $HOME/.ssh/id_rsa && cat $HOME/.ssh/id_rsa.pub' | cat >> `su $user -c 'echo $HOME'`/.ssh/authorized_keys
    printf "Stop PostgreSQL slave server on $slave_host and remove cluster\n"
    
    su $user -c 'ssh-keyscan '$slave_host' >> $HOME/.ssh/known_hosts'
    su $user -c 'ssh '$user'@'$slave_host' pg_ctl stop -m fast -D '$_data_dir''
    su $user -c 'ssh '$user'@'$slave_host' rm -rf '$_data_dir''
    su $user -c 'ssh '$user'@'$slave_host' mkdir -p '$wal_dir''
}

print_license

# Detect what is it Mac OS X or Linux
manual_master_host="Add master ip address manual"
if [[ `uname` == 'Linux' ]]; then
	platform='linux'
    i=1;
    while read item; do
        master_hosts[$i]="$item"
        i=$((i+1))
    done < <(ifconfig  | grep 'inet addr:'| grep -v '127.0.0.1' | cut -d: -f2 | awk '{ print $1}')
elif [[ `uname` == 'Darwin' ]]; then
	platform='macosx'
    i=1;
    while read item; do
        master_hosts[$i]="$item"
        i=$((i+1))
    done < <(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | cut -d: -f2 | awk '{print $2}')
fi

if [[ $platform == 'unknown' ]]; then
	echo "Error. Platform not supported. Exit"
	exit 2
fi

# Firs, user must select interface(ip address) by which will be configured stremaing replication
master_hosts[$i]="$manual_master_host"
i=$((i+1))

echo "We found the following worked interfaces:"
for ((k = 1; k < $i; k++)); do
    echo " $k: ${master_hosts[$k]}"
done

echo -n "Please, enter a interface number to configure master or 0 to exit: "
read host_n

if ! [ "$host_n" -eq "$host_n" 2> /dev/null ]; then
    echo "Error: $host_n isn't a number, bye."
    exit 2
fi

if [ "$host_n" -lt 1 -o "$host_n" -ge $i -o "$host_n" -eq 0 ]; then
    echo "No action taken, bye."
    exit
fi
if [ "${master_hosts[$host_n]}" == "$manual_master_host" ]; then
    echo -n "Please, enter a ip address of this master server: "
    read master_hosts[$host_n]
fi

configure_user
printf "Master configuread as $user@${master_hosts[$host_n]}\n"
read -r -p "It is correct? [y/N]" correct
while ! [[ $correct =~ ^([yY][eE][sS]]|[yY])$ ]]; do
    configure_user
    printf "Master configuread as $user@${master_hosts[$host_n]}\n"
    read -r -p "It is correct? [y/N]" correct
done

su $user -c 'ssh-keygen -t rsa -P "" -f $HOME/.ssh/id_rsa'
su $user -c 'cat $HOME/.ssh/id_rsa.pub > $HOME/.ssh/authorized_keys'

configure_slave
read -r -p "Add enother slave server? [y/N]" another
while [[ $another =~ ^([yY][eE][sS]|[yY])$ ]]; do
    configure_slave
    read -r -p "Add enother slave server? [y/N]" another
done

for ((i = 0; i < ${#slave_hosts[@]}; i++)); do
    printf " $i: ${slave_hosts[$i]} ${slave_data_dirs[$i]} ${slave_postgresql_confs[$i]} ${slave_pg_hba_confs[$i]}\n"
done

configure_master

read -r -p "Begin copy master cluster to slave servers? [y/N]" response
if [[ $response =~ ^([yY][eE][sS]|[yY])$ ]]; then
    # Begin copy data to slave servers
    for ((i = 0; i < ${#slave_hosts[@]}; i++)); do
        printf "Begin copy cluster to ${slave_hosts[$i]}\n"
        su $user -c 'ssh '$user'@'${slave_hosts[$i]}' pg_basebackup -U '$user' -D '${slave_data_dirs[$i]}' -h '${master_hosts[$host_n]}' -P'
        echo -e "standby_mode = on\nprimary_conninfo = 'host=${master_hosts[$host_n]} port=5432 user=$user'\nrestore_command = 'cp $wal_dir/%f %p'\narchive_cleanup_command = 'pg_archivecleanup $wal_dir  %r'" | su $user -c 'ssh '$user'@'${slave_hosts[$i]}' "cat > '${slave_data_dirs[$i]}'/recovery.conf"'
        echo "hot_standby = on" | su $user -c 'ssh '$user'@'${slave_hosts[$i]}' "cat >> '${slave_postgresql_confs[$i]}'"'
        su $user -c 'ssh -t '$user'@'$slave_host' pg_ctl start -D '${slave_data_dirs[$i]}' -s -w'
    done
fi

exit 0