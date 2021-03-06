#!/bin/bash
 
# Deploy Pivotal HD Cluster and Services
# 
# Note: The default pwd is /home/vagrant. 
#
# Note: By default, Vagrant shares your project directory (that is the one with the Vagrantfile) 
#       to the /vagrant directory in your guest VMs. 
# 
# Note: 'root' is the default user. You can not change the root user in the script. "$sudo su - gpadmin" will not work!
#       Use the inline syntax instead: "$su - -c "some command" gpadmin".


[ "$#" -ne 7 ] && (echo "Expects 7 input agreements but found: $#"; exit 1)

# Number of cores per node
VCORES_PER_NODE=1

# Number of local discs per node
DISKS_PER_NODE=3
  
# Sets the cluster name to be used in PCC (Pivotal Control Center)
CLUSTER_NAME=$1
 
# List of Hadoop services to be deployed with this installation.
# Note: Hive is disabled because phd2 and ph3 VMs are configured with just 1GB of memory (Vagrantfile)! To enable Hive 
# increase the memory of the VMs to 2GB at least (edit Vagrantfile) and then add 'hive' to the $SERVICES variable.
# Alternativly if you don't have enough physical memory then you can remove one VM (phd3 for example) and increase the memory
# of the remaining VMs. For this you need to remove phd3 definition from the Vagrangfile and from the $SLAVE_NODES list.
SERVICES=$2
 
# Sets the dns name of the VM used as Master node for all Hadoop services (e.g. namenode, hawq master, jobtracker ...)
# Note: Master node is not an Admin node (where PCC runs). By convention the Admin node is the pcc.localdomain. 
MASTER_NODE=$3

# List of worker nodes
WORKER_NODES=$4

# Amount of memory allocated for this node (VM)
PHD_MEMORY_MB=$5
 
JAVA_RPM_PATH=$6 

# HDFS replication factor - relative to the number of DataNodes
HDFS_REPLICATION_FACTOR=$7 

SECOND_MASTER_NODE=$8 
 
# By default the HAWQ master is collocated with the other master services.
HAWQ_MASTER=$MASTER_NODE
  
# By default all nodes will be used as Hawq segment hosts. Edit the $HAWQ_SEGMENT_HOSTS variable to change this setup.  
HAWQ_SEGMENT_HOSTS=$WORKER_NODES
 
# Client node defaults to the MASTER node 
CLIENT_NODE=$MASTER_NODE

# By default the GemfireXD Locator is collocated with the other master services.
GFXD_LOCATOR=$MASTER_NODE

# GemfireXD servers. Remove the master node if present
GFXD_SERVERS=${WORKER_NODES/$MASTER_NODE,/}
 
# Root password required for creating gpadmin users on the cluster nodes. 
# (By default Vagrant creates 'vagrant' root user on every VM. The password is 'vagrant' - used below)
ROOT_PASSWORD=vagrant
 
# Non-empty password to be used for the gpadmin user. Required by the PHD installation. 
GPADMIN_PASSWORD=gpadmin

is_service_enabled() {
	local service_name="$1"
	if [[ $SERVICES == *$service_name* ]]
	then
        # enabled
		return 0
	else
        # disabled
		return 1 
	fi	
}

min() {
	if (( $1 < $2 ))
	then
		echo $1
	else
		echo $2
	fi
}

max() {
	if (( $1 > $2 ))
	then
		echo $1
	else
		echo $2
	fi
}


echo "********************************************************************************"
echo "********************************************************************************"
echo "*                 Pre-Deploy Cluster: $CLUSTER_NAME                    "
echo "********************************************************************************"
echo "********************************************************************************"
# Cluster is deployed as gpadmin user!
 
# Pivotal HD manager deploys clusters using input from the cluster configuration directory. This cluster 
# configuration directory contains files that describes the topology and configuration for the cluster and the 
# installation procedure.
 
# Fetch the default Cluster Configuration Templates. 
su - -c "icm_client fetch-template -o ~/ClusterConfigDir" gpadmin
 
# Use the following convention to assign cluster hosts to Hadoop service roles. All changes are 
# applied to the ~/ClusterConfigDir/clusterConfig.xml file, generated in the previous step. 
# Note: By default HAWQ_MASTER=MASTER_NODE, CLIENT_NODE=MASTER_NODE and HAWQ_SEGMENT_HOSTS=WORKER_NODES
# ---------------------------------------------------------------------------------------------------------
#      Hosts        |                       Services
# ---------------------------------------------------------------------------------------------------------
# MASTER_NODE       | client, namenode, secondarynameonde, yarn-resourcemanager, mapreduce-historyserver, 
#                   | hbase-master,hive-server,hive-metastore,hawq-master,hawq-standbymaste,hawq-segment,
#                   | gpxf-agent
#                   |
# WORKER_NODES       | datanode,yarn-nodemanager,zookeeper-server,hbase-regionserver,hawq-segment,gpxf-agent 
# ---------------------------------------------------------------------------------------------------------

# Apply the mapping convention (above) to the default clusterConfig.xml.

# remove services not supported by the clusterConfig.xml
SUPPORTED_SERVICES=${SERVICES/,graphlab/}

sed -i "\
s/<securityEnabled>true<\/securityEnabled>/<securityEnabled>false<\/securityEnabled>/g;\
s/<clusterName>.*<\/clusterName>/<clusterName>$CLUSTER_NAME<\/clusterName>/g;\
s/<services>.*<\/services>/<services>$SUPPORTED_SERVICES<\/services>/g;\
s/<client>.*<\/client>/<client>$CLIENT_NODE<\/client>/g;\
s/<namenode>.*<\/namenode>/<namenode>$MASTER_NODE<\/namenode>/g;\
s/<datanode>.*<\/datanode>/<datanode>$WORKER_NODES<\/datanode>/g;\
s/<standbynamenode>.*<\/standbynamenode>/<standbynamenode>$SECOND_MASTER_NODE<\/standbynamenode>/g;\
s/<journalnode>.*<\/journalnode>/<journalnode>$WORKER_NODES<\/journalnode>/g;\
s/<yarn-resourcemanager>.*<\/yarn-resourcemanager>/<yarn-resourcemanager>$MASTER_NODE<\/yarn-resourcemanager>/g;\
s/<yarn-nodemanager>.*<\/yarn-nodemanager>/<yarn-nodemanager>$WORKER_NODES<\/yarn-nodemanager>/g;\
s/<mapreduce-historyserver>.*<\/mapreduce-historyserver>/<mapreduce-historyserver>$MASTER_NODE<\/mapreduce-historyserver>/g;\
s/<zookeeper-server>.*<\/zookeeper-server>/<zookeeper-server>$WORKER_NODES<\/zookeeper-server>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml
#s/<zookeeper-server>.*<\/zookeeper-server>/<zookeeper-server>$MASTER_NODE<\/zookeeper-server>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml

# Configure the YARN and Heap memory relative to the available VM memory size

total_yarn_ram_mb=$((PHD_MEMORY_MB<4096?PHD_MEMORY_MB - 128:PHD_MEMORY_MB - 512))
min_container_ram_mb=$((PHD_MEMORY_MB<4096?256:512))
containers_per_node=$(( $(min $(min $((2 * VCORES_PER_NODE)) $(( (18 * DISKS_PER_NODE)/10))) $(($total_yarn_ram_mb/$min_container_ram_mb)) ) ))
ram_per_container=$(max $min_container_ram_mb $(($total_yarn_ram_mb / $containers_per_node)) )

yarn_nodemanager_resource_memory_mb=$(($containers_per_node * $ram_per_container))
yarn_scheduler_minimum_allocation_mb=$ram_per_container
yarn_scheduler_maximum_allocation_mb=$yarn_nodemanager_resource_memory_mb
mapreduce_map_memory_mb=$ram_per_container
mapreduce_reduce_memory_mb=$(( 2 * $ram_per_container ))
mapreduce_map_java_opts=$(( (8 * $ram_per_container)/10 ))
mapreduce_reduce_java_opts=$(( (8 * 2 * $ram_per_container)/10 ))
yarn_app_mapreduce_am_resource_mb=$((2 * $ram_per_container))
yarn_app_mapreduce_am_command_opts=$(( (8 * $yarn_app_mapreduce_am_resource_mb)/10 ))

heap_memory_mb=$yarn_nodemanager_resource_memory_mb

sed -i "\
s/<yarn.nodemanager.resource.memory-mb>.*<\/yarn.nodemanager.resource.memory-mb>/<yarn.nodemanager.resource.memory-mb>$total_yarn_ram_mb<\/yarn.nodemanager.resource.memory-mb>/g;\
s/<yarn.scheduler.minimum-allocation-mb>.*<\/yarn.scheduler.minimum-allocation-mb>/<yarn.scheduler.minimum-allocation-mb>$yarn_scheduler_minimum_allocation_mb<\/yarn.scheduler.minimum-allocation-mb>/g;\
s/<dfs.namenode.heapsize.mb>.*<\/dfs.namenode.heapsize.mb>/<dfs.namenode.heapsize.mb>$heap_memory_mb<\/dfs.namenode.heapsize.mb>/g;\
s/<dfs.datanode.heapsize.mb>.*<\/dfs.datanode.heapsize.mb>/<dfs.datanode.heapsize.mb>$heap_memory_mb<\/dfs.datanode.heapsize.mb>/g;\
s/<yarn.resourcemanager.heapsize.mb>.*<\/yarn.resourcemanager.heapsize.mb>/<yarn.resourcemanager.heapsize.mb>$heap_memory_mb<\/yarn.resourcemanager.heapsize.mb>/g;\
s/<yarn.nodemanager.heapsize.mb>.*<\/yarn.nodemanager.heapsize.mb>/<yarn.nodemanager.heapsize.mb>$heap_memory_mb<\/yarn.nodemanager.heapsize.mb>/g;\
s/<hbase.heapsize.mb>.*<\/hbase.heapsize.mb>/<hbase.heapsize.mb>$heap_memory_mb<\/hbase.heapsize.mb>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml

sed -i "s/<\/configuration>/\
\n<property>\n  <name>mapreduce.map.memory.mb<\/name>\n  <value>$mapreduce_map_memory_mb<\/value>\n<\/property>\
\n<property>\n  <name>mapreduce.reduce.memory.mb<\/name>\n  <value>$mapreduce_reduce_memory_mb<\/value>\n<\/property>\
\n<property>\n  <name>yarn.app.mapreduce.am.resource.mb<\/name>\n  <value>$yarn_app_mapreduce_am_resource_mb<\/value>\n<\/property>\
\n<\/configuration> /g;" /home/gpadmin/ClusterConfigDir/yarn/mapred-site.xml 

sed -i "s/<\/configuration>/\
\n<property>\n    <name>dfs.replication<\/name>\n    <value>$HDFS_REPLICATION_FACTOR<\/value>\n<\/property>\
\n<\/configuration> /g;" /home/gpadmin/ClusterConfigDir/hdfs/hdfs-site.xml

if (is_service_enabled "hbase"); then
sed -i "\
s/<hbase-master>.*<\/hbase-master>/<hbase-master>$MASTER_NODE<\/hbase-master>/g;\
s/<hbase-regionserver>.*<\/hbase-regionserver>/<hbase-regionserver>$WORKER_NODES<\/hbase-regionserver>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml
fi

if (is_service_enabled "hive"); then
sed -i "\
s/<hive-server>.*<\/hive-server>/<hive-server>$MASTER_NODE<\/hive-server>/g;\
s/<hive-metastore>.*<\/hive-metastore>/<hive-metastore>$MASTER_NODE<\/hive-metastore>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml
fi

if (is_service_enabled "hawq"); then
sed -i "\
s/<hawq-master>.*<\/hawq-master>/<hawq-master>$HAWQ_MASTER<\/hawq-master>/g;\
s/<hawq-standbymaster>.*<\/hawq-standbymaster>/<hawq-standbymaster>$HAWQ_MASTER<\/hawq-standbymaster>/g;\
s/<hawq-segment>.*<\/hawq-segment>/<hawq-segment>$HAWQ_SEGMENT_HOSTS<\/hawq-segment>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml
fi

if (is_service_enabled "pxf"); then
sed -i "\
s/<pxf-service>.*<\/pxf-service>/<pxf-service>$HAWQ_MASTER,$WORKER_NODES<\/pxf-service>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml
echo '/usr/lib/gphd/gfxd/lib/gemfirexd.jar' >> /home/gpadmin/ClusterConfigDir/pxf/pxf-public.classpath
fi

if (is_service_enabled "gfxd"); then
if (! grep -q "gfxd-locator" "/home/gpadmin/ClusterConfigDir/clusterConfig.xml"); then
sed -i "\
s/<\/hostRoleMapping>/\
\n         <gfxd>\
\n            <gfxd-locator>$GFXD_LOCATOR<\/gfxd-locator>\
\n            <gfxd-server>$GFXD_SERVERS<\/gfxd-server>\
\n         <\/gfxd>\
\n     <\/hostRoleMapping>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml
fi
sed -i "\
s/<gfxd-locator>.*<\/gfxd-locator>/<gfxd-locator>$GFXD_LOCATOR<\/gfxd-locator>/g;\
s/<gfxd-server>.*<\/gfxd-server>/<gfxd-server>$GFXD_SERVERS<\/gfxd-server>/g;" /home/gpadmin/ClusterConfigDir/clusterConfig.xml
fi 
xmlwf /home/gpadmin/ClusterConfigDir/clusterConfig.xml  
 
# Set vm.overcommit_memory to 1 to prevent OOM and other VM issues. 
sed -i 's/vm.overcommit_memory = 2/vm.overcommit_memory = 0/g' /usr/lib/gphd/gphdmgr/hawq_sys_config/sysctl.conf

echo "********************************************************************************"
echo "********************************************************************************"
echo "*                 Deploy Cluster: $CLUSTER_NAME                    "
echo "********************************************************************************"
echo "********************************************************************************"

# Use ICM to perform the deploy
# Note: deploy expects user inputs like root and gpadmin passwords. The 'expect' tool is used to emulate this user interaction. 
cat > /home/gpadmin/deploy_cluster.exp <<EOF
#!/usr/bin/expect -f
 
set timeout 100
 
spawn icm_client deploy -c /home/gpadmin/ClusterConfigDir -s -i -d -j $JAVA_RPM_PATH -y /usr/lib/gphd/gphdmgr/hawq_sys_config/
 
expect "Please enter the root password for the cluster nodes:"
send -- "$ROOT_PASSWORD\r"
expect "PCC creates a gpadmin user on the newly added cluster nodes (if any). Please enter a non-empty password to be used for the gpadmin user:"
send -- "$GPADMIN_PASSWORD\r"
send -- "\r"
expect eof
EOF

chown gpadmin:gpadmin /home/gpadmin/deploy_cluster.exp; chmod a+x /home/gpadmin/deploy_cluster.exp
 
# Prepare all PHD hosts and perform the deploy
su - -c "expect -f /home/gpadmin/deploy_cluster.exp" gpadmin

printf "\n"

# Wait until deployment complete (e.g. not in install_progress)
cstatus="unknown"; while [[ "$cstatus" != *"installed"* && "$cstatus" != *"install_failed"* ]]; do cstatus=$(icm_client list | grep "$CLUSTER_NAME"| awk '{ print $11}');  echo "[$(date +'%H:%M:%S')] $CLUSTER_NAME Status: $cstatus "; sleep 20; done

echo "********************************************************************************"
echo "*                 Post-Deploy Cluster: $CLUSTER_NAME                    "
echo "********************************************************************************"

# Fix Hive's java5 override. 
sshpass -p $ROOT_PASSWORD ssh -o StrictHostKeyChecking=no $HAWQ_MASTER 'sudo ln -f -s /usr/java/default/bin/java /usr/bin/java'


if (is_service_enabled "hawq"); then
   echo "---------------------------------------------------------------------------------"
   echo "*                    HAWQ - post deploy configuration                   "
   echo "---------------------------------------------------------------------------------"

   su - -c "echo $HAWQ_SEGMENT_HOSTS  | tr , '\n' > /home/gpadmin/HAWQ_Segment_Hosts.txt" gpadmin
 
   su - -c "\
    scp /home/gpadmin/HAWQ_Segment_Hosts.txt gpadmin@$HAWQ_MASTER:/home/gpadmin/HAWQ_Segment_Hosts.txt;\
    ssh gpadmin@$HAWQ_MASTER 'source /usr/local/hawq/greenplum_path.sh;\
    /usr/local/hawq/bin/gpssh-exkeys -f /home/gpadmin/HAWQ_Segment_Hosts.txt -p $GPADMIN_PASSWORD'" gpadmin
fi
 
echo "********************************************************************************"
echo "*                 Start Cluster: $CLUSTER_NAME                                  "
echo "********************************************************************************"
 
su - -c "icm_client list" gpadmin
  
su - -c "icm_client start -l $CLUSTER_NAME" gpadmin

if (is_service_enabled "hawq"); then
   echo "---------------------------------------------------------------------------------"
   echo "*                       Initialise HAWQ   									  "
   echo "---------------------------------------------------------------------------------"

   su - -c "ssh gpadmin@$HAWQ_MASTER '/etc/init.d/hawq init'" gpadmin;
fi

if (is_service_enabled "gfxd"); then
   echo "---------------------------------------------------------------------------------"
   echo "*                       Initialise GemFireXD   							      "
   echo "---------------------------------------------------------------------------------"

   echo "Initialize GFXD locator: $GFXD_LOCATOR"
   su - -c "ssh gpadmin@$GFXD_LOCATOR 'export GFXD_JAVA=/usr/java/default/bin/java; mkdir /tmp/locator; \
       nohup sqlf locator start -peer-discovery-address=$GFXD_LOCATOR -dir=/tmp/locator -jmx-manager-start=true -jmx-manager-http-port=7075 & '" gpadmin

   echo "Start the Pulse monitoring tool by opening: http://10.211.55.101:7075/pulse/clusterDetail.html  username: admin and password: admin. "

   for gfxd_server in ${GFXD_SERVERS//,/ }
   do
     echo "Initialize GFXD server: $gfxd_server"
     su - -c "ssh gpadmin@$gfxd_server 'export GFXD_JAVA=/usr/java/default/bin/java; mkdir /tmp/server; \
      nohup sqlf server start -locators=$GFXD_LOCATOR[10334] -bind-address=$gfxd_server -client-port=1528 -dir=/tmp/server &'" gpadmin
   done
fi

if (is_service_enabled "graphlab"); then
   echo "---------------------------------------------------------------------------------"
   echo "*                       Instal Hamster & GraphLab   						      "
   echo "---------------------------------------------------------------------------------"

   CLIENT_AND_WORKER_NODES=$CLIENT_NODE,$WORKER_NODES
   for graphlab_server in ${CLIENT_AND_WORKER_NODES//,/ }
   do
     echo "Install Hamster and GraphLab  on server: $graphlab_server"  
     sshpass -p $ROOT_PASSWORD ssh -o StrictHostKeyChecking=no $graphlab_server 'sudo yum -y install hamster-core openmpi hamster-rte graphlab'
   done
fi