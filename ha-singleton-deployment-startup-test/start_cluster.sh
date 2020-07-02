#!/bin/sh

home=$(dirname $(readlink -f $0))

set -e -u

export JBOSS_HOME=/opt/jboss-eap-7.1.1
#export JBOSS_HOME=/local/obadmud/opt/jboss-eap-7.3.1

# Test OOM on given node
test_oom=node2

# Stop test after delay seconds
if [ "$test_oom" = true ]; then
   auto_stop_delay=80
else
   auto_stop_delay=600
fi
enable_trace_logging=false

tmpdir=/tmp/$USER/ha-singleton-startup-test

rm -fr $tmpdir
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

function enable_trace_logging() {

    local filename=$1

    # Profile verbose of everything...
    perl -p -i -e '
        s{<level name="\w+"/>}{<level name="TRACE"/>};
    ' $filename

}

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

function adapt_default_election_policy() {

    local filename=$1

    #   <subsystem xmlns="urn:jboss:domain:singleton:1.0">
    #       <singleton-policies default="default">
    #           <singleton-policy name="default" cache-container="server">
    #               <simple-election-policy/>
    #
    perl -p -i -e '
                s{<simple-election-policy/>}{
                    <simple-election-policy>
                        <name-preferences>node1 node2</name-preferences>
                    </simple-election-policy>
                 };
    ' $filename

}

function start_cluster_nodes() {

    for nodeId in 2 1 ; do

       multicast_address=239.2.$(($port_offset_base / 100)).1
       port_offset=$(($port_offset_base + ($nodeId - 1) * 10))

       nodeDir="$tmpdir/jb-$nodeId"

       mkdir -p $nodeDir

       export JBOSS_BASE_DIR=$nodeDir/standalone

       cp -a -r $JBOSS_HOME/standalone $nodeDir/

       # Manual deployment that should be available on start
       cp -a $jar $JBOSS_BASE_DIR/deployments/

       conf_file=$JBOSS_BASE_DIR/configuration/standalone-ha.xml
       
       if [ $env_number != "000" ]; then
           adapt_jboss_ports $conf_file
       fi

       if [ "$enable_trace_logging" = "true" ]; then
           export GC_LOG="true"
           enable_trace_logging $conf_file
       fi

       # adapt_default_election_policy $conf_file

       if [ -n "$test_oom" -a $nodeId -eq 2 ]; then
          export JAVA_OPTS="-Xmx512m"
       fi

       ${JBOSS_HOME}/bin/standalone.sh -c standalone-ha.xml \
            -Dtest.outfile.prefix="ha-singleton-provider-is-" \
            -Dtest.outdir="$tmpdir" \
            -Dtest.oom=node2 \
            -Djboss.node.name=node$nodeId \
            -Djboss.default.multicast.address=$multicast_address \
            -Djboss.socket.binding.port-offset=$port_offset > "$nodeDir/console.log" &

       if [ -n "$test_oom" -a $nodeId -eq 2 ]; then
            # Give node2 time to become singleton provider
            sleep 20
       fi
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

# Auto kill after timeout?
if [ $auto_stop_delay -gt 0 ]; then

    delay=10
    delay_count=$(($auto_stop_delay / $delay))

    for i in $(seq $delay_count -1 1); do
       echo Wating for Ctrl-C to kill $job_pids or timeout in about $(($i * $delay)) seconds ...
       sleep $delay
    done

    echo "Unregistering cleanup callback and shutting down"
    trap
    trap - $trap_sigs

    kill_jobs

fi

echo Wating for shutdown of $job_pids ...
wait

leader_count=$(ls -1 $tmpdir/ha-singleton-provider-is-* | wc -l)

if [ $leader_count -ne 1 ]; then
    echo >&2 "ERROR: Got leader count $leader_count != 1"
    exit 1
fi

