#!/bin/bash
export DEBIAN_FRONTEND=noninteractive 

function die() {
	echo $*
	exit 1
}

echo debconf shared/accepted-oracle-license-v1-1 select true | debconf-set-selections
echo debconf shared/accepted-oracle-license-v1-1 seen true | debconf-set-selections

# Add a local apt-cacher-ng proxy per https://docs.docker.com/examples/apt-cacher-ng/
# dockerhost=`/sbin/ip route|awk '/default/ { print $3 }'`
# echo "Acquire::HTTP::Proxy \"http://${dockerhost}:3142\";" >> /etc/apt/apt.conf.d/01proxy
# echo 'Acquire::HTTPS::Proxy "false";' >> /etc/apt/apt.conf.d/01proxy
# echo 'Acquire::http::Proxy { download.oracle.com DIRECT; };' >> /etc/apt/apt.conf.d/01proxy

apt-get update || die
apt-get install -y --no-install-recommends software-properties-common || die
add-apt-repository ppa:webupd8team/java || die
apt-get update || die
apt-get install -y --force-yes --no-install-recommends oracle-java8-installer oracle-java8-set-default || die
export JAVA_HOME=/usr/lib/jvm/java-8-oracle || die

apt-get install -y -q wget dialog curl sudo lsof vim axel telnet || die

if [ -f /tmp/install_cloudera_repositories.sh ]; then
    . /tmp/install_cloudera_repositories.sh || die
fi

apt-get update || die

echo "Install Zookeeper"
apt-get -y install zookeeper-server || die "Unable to install zookeeper-server"

echo "Removing Max Client Connections Limit for Zookeeper"
sed -i '/maxClientCnxns/s/=.*/=0/' /etc/zookeeper/conf/zoo.cfg

echo "Start Zookeeper"
service zookeeper-server init || die "Unable to init zookeeper-server"
service zookeeper-server start || die "Unable to start zookeeper-server"
service zookeeper-server stop || die "Unable to stop zookeeper-server"

apt-get -y install hadoop-conf-pseudo impala impala-server impala-state-store impala-catalog impala-shell || die

#CDH5-Installation-Guide Step 1 - Format the NameNode
echo "Step 1 - Format the NameNode"
sudo -u hdfs hdfs namenode -format || die

#CDH5-Installation-Guide Step 2 - Start HDFS
echo "Step 2 - Start HDFS"
bash -c 'for x in `cd /etc/init.d ; ls hadoop-hdfs-*` ; do sudo service $x start ; done' || die

#CDH5-Installation-Guide Step 3 - Create the directories needed for Hadoop processes
echo "Step 3 - Create the directories needed for Hadoop processes"
/usr/lib/hadoop/libexec/init-hdfs.sh || die

#CDH5-Installation-Guide Step 4: Verify the HDFS File Structure
echo "Step 4: Verify the HDFS File Structure"
sudo -u hdfs hadoop fs -ls -R / || die

#CDH5-Installation-Guide Step 5 - Start Yarn
echo "Step 5 - Start Yarn"
service hadoop-yarn-resourcemanager start || die
service hadoop-yarn-nodemanager start || die
service hadoop-mapreduce-historyserver start || die

#CDH5-Installation-Guide Step 6 - Create User Directories
echo "Step 6 - Create User Directories"
sudo -u hdfs hdfs dfs -mkdir -p /user/hadoop || die
sudo -u hdfs hdfs dfs -chown hadoop /user/hadoop || die
hadoop fs -mkdir -p       /tmp || die
sudo -u hive hdfs dfs -mkdir -p       /user/hive/warehouse || die
hadoop fs -chmod g+w   /tmp || die
sudo -u hive hdfs dfs -chmod g+w   /user/hive/warehouse || die
sudo -u hdfs hdfs dfs -mkdir -p /hbase || die
sudo -u hdfs hdfs dfs -chown hbase /hbase || die

# For samza logs
mkdir /var/log/samza
chown yarn:yarn /var/log/samza

echo "Add an HDH user and include as sudoer"
useradd hdh
echo "hdh:hdh" | chpasswd
usermod -a -G sudo hdh
mkdir -p /home/hdh
chown hdh:hdh /home/hdh

echo "Add folder for HDH"
sudo -u hdfs hdfs dfs -mkdir -p /HDH || die "Unable to make HDFS directory /HDH"
sudo -u hdfs hdfs dfs -chown hdh /HDH || die "Unable to change owner of HDFS directory /HDH"

#CDH5-Installation-Guide Install HBase
echo "Install Cloudera Components"
#apt-get -y install hadoop-kms hadoop-kms-server hive hbase hbase-thrift hbase-master pig hue oozie oozie-client spark-core spark-master spark-worker spark-history-server spark-python || die
apt-get -y install hadoop-kms hadoop-kms-server hive hbase hbase-thrift hbase-master hbase-regionserver pig hue oozie oozie-client || die

#Use standalone Zookeeper
echo "export HBASE_MANAGES_ZK=true" >> /etc/hbase/conf.dist/hbase-env.sh

echo '<?xml version="1.0"?>' > /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '<configuration>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"

# For now, use standalone mode with embedded Zookeeper, but on different port.
# Tried to use shared zookeeper, but ran into issues.  See below for how to do that.
# http://serverfault.com/questions/599661/could-not-start-zk-at-requested-port-of-2181-while-export-hbase-manages-zk-fals
echo '    <property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <name>hbase.cluster.distributed</name>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <value>false</value>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '    </property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"

# Use a different port than 2181 to avoid interfering with the usual Zookeeper
echo '    <property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <name>hbase.zookeeper.property.clientPort</name>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <value>2182</value>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '    </property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"

# This is actually the default for maxClientCnxns, but a nice reminder
echo '    <property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <name>hbase.zookeeper.property.maxClientCnxns</name>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <value>300</value>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '    </property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"

# When running pseudo-distributed, I would see timeouts on zookeeper sessions, so
# I bumped up the timeout. This is probably unnecessary in standalon mode,
# but I'm leaving it just because it worked.
echo '    <property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <name>hbase.zookeeper.session.timeout</name>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <value>1800000</value>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '    </property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"

#Don't abort coprocessors on error
echo '    <property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <name>hbase.coprocessor.abortonerror</name>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '        <value>false</value>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '    </property>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"
echo '</configuration>' >> /etc/hbase/conf.dist/hbase-site.xml || die "Unable to update hbase-site.xml"

#Configure Oozie
update-alternatives --set oozie-tomcat-conf /etc/oozie/tomcat-conf.http || die
sudo -u hdfs hadoop fs -chown oozie:oozie /user/oozie || die
sudo oozie-setup sharelib create -fs hdfs://localhost -locallib /usr/lib/oozie/oozie-sharelib-yarn || die
#Initiate Oozie Database
oozie-setup db create -run || die


#Create HUE Secret Key
sed -i 's/secret_key=/secret_key=_S@s+D=h;B,s$C%k#H!dMjPmEsSaJR/g' /etc/hue/conf/hue.ini || die

apt-get -y install solr-server hue-search
sudo -u hdfs hadoop fs -mkdir -p /solr
sudo -u hdfs hadoop fs -chown solr /solr
mv /etc/default/solr.docker /etc/default/solr
service hbase-master start || die
solrctl init

# Install Kafka per https://www.digitalocean.com/community/tutorials/how-to-install-apache-kafka-on-ubuntu-14-04
echo "Install Kafka"
useradd kafka -m || die
echo "kafka:kafka" | chpasswd  || die # Note, this is not secure
adduser kafka sudo || die

KAFKA_HOME=/home/kafka
sudo -u kafka mkdir -p ${KAFKA_HOME}/Downloads || die
sudo -u kafka wget "http://mirror.cc.columbia.edu/pub/software/apache/kafka/0.8.2.1/kafka_2.10-0.8.2.1.tgz" -O ${KAFKA_HOME}/Downloads/kafka.tgz || die
sudo -u kafka mkdir -p ${KAFKA_HOME}/kafka || die
sudo -u kafka tar --strip 1 -xvzf ${KAFKA_HOME}/Downloads/kafka.tgz -C ${KAFKA_HOME}/kafka || die
sudo -u kafka echo "auto.create.topics.enable = true" >> ${KAFKA_HOME}/kafka/config/server.properties || die
sudo -u kafka echo "delete.topic.enable = true" >> ${KAFKA_HOME}/kafka/config/server.properties || die