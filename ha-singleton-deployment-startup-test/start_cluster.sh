#!/bin/sh

home=$(dirname $(readlink -f $0))

set -e -u

if [ -z "${JBOSS_HOME+x}" ]; then
    export JBOSS_HOME=/opt/jboss-eap-7.1.1
fi

tmpdir=/tmp/$USER/ha-singleton-startup-test
mkdir -p $tmpdir

jar="$home/../ha-singleton-deployment/target/ha-singleton-deployment.jar"

test -r "$jar" || ( echo "Can't find '$jar'" - build first  ; exit 1)

if [ -z "${GTSENV+x}" ]; then
   env_number="000"
else
   env_number=$GTSENV 
fi

export port_offset_prefix=1${env_number#0} 
export port_offset_base=$(($port_offset_prefix * 100))

function adapt_jboss_ports() {

    local filename=$1

    perl -p -i -e '

        my $multicast_port_prefix=$ENV{'port_offset_prefix'};

        s/(socket-binding name="ajp" port)=".*?"/$1="80"/;
        s/(socket-binding name="http" port)=".*?"/$1="85"/;
        s/(socket-binding name="https" port)=".*?"/$1="84"/;
        s/(socket-binding name="jgroups-tcp" interface="private" port)=".*?"/$1="81"/;
        s/(socket-binding name="jgroups-tcp-fd".* port)=".*?"/$1="87"/;
        s/(socket-binding name="management-http".* port)=".*?"/$1="88"/;
        s/(socket-binding name="management-https".* port)=".*?"/$1="89"/;
        s/(socket-binding name="txn-recovery-environment" port)=".*?"/$1="82"/;
        s/(socket-binding name="txn-status-manager" port)=".*?"/$1="83"/;

        s/(socket-binding name="jgroups-udp" .* port)=".*?"/$1="10740"/;
        s/(socket-binding name="jgroups-udp-fd" .* port)=".*?"/$1="10741"/;

        # Map multicast ports to shared offset
        s/(socket-binding name="jgroups-mping" .* multicast-port)="\d+"/$1="${multicast_port_prefix}01"/;
        s/(socket-binding name="jgroups-udp" .* multicast-port)="\d+"/$1="${multicast_port_prefix}02"/;
        s/(socket-binding name="modcluster" .* multicast-port)="\d+"/$1="${multicast_port_prefix}03"/;

    ' $filename

}

function start_cluster_nodes() {

    for nodeId in 1 2 ; do

       multicast_address=239.2.$(($port_offset_base / 100)).1
       port_offset=$(($port_offset_base + ($nodeId - 1) * 10))

       nodeDir="$tmpdir/jb-$nodeId"

       rm -fr $nodeDir
       mkdir -p $nodeDir

       export JBOSS_BASE_DIR=$nodeDir/standalone

       cp -a -r $JBOSS_HOME/standalone $nodeDir/

       # Manual deployment that should be available on start
       cp -a $jar $JBOSS_BASE_DIR/deployments/

       rm -f $tmpdir/ha-singleton-provider-is-*

       if [ $env_number != "000" ]; then
           adapt_jboss_ports $JBOSS_BASE_DIR/configuration/standalone-ha.xml
       fi

       ${JBOSS_HOME}/bin/standalone.sh -c standalone-ha.xml \
            -Dtest.outfile.prefix="ha-singleton-provider-is-" \
            -Dtest.outdir="$tmpdir" \
            -Djboss.node.name=node$nodeId \
            -Djboss.default.multicast.address=$multicast_address \
            -Djboss.socket.binding.port-offset=$port_offset &

    done

}

start_cluster_nodes

job_pids=$(jobs -p)

trap_sigs="0 3 10 ERR INT"

function kill_jobs() {
   echo Killing $job_pids
   pkill -P $(echo $job_pids | sed 's/\s\s*/,/g')
}

trap kill_jobs $trap_sigs

delay=4
for i in $(seq 10 -1 1); do
   echo Wating for Ctrl-C to kill $job_pids or timeout in about $(($i * $delay)) seconds ...
   sleep $delay
done

echo "Unregistering cleanup callback and shutting down"
trap
trap - $trap_sigs

kill_jobs


echo Wating for shutdown of $job_pids ...
wait

leader_count=$(ls -1 $tmpdir/ha-singleton-provider-is-* | wc -l)

if [ $leader_count -ne 1 ]; then
    echo >&2 "ERROR: Got leader count $leader_count != 1"
    exit 1
fi

