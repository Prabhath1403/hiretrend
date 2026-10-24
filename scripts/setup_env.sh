#!/usr/bin/env bash
# ==============================================================================
# HireTrend - Environment Setup Script (Ubuntu 22.04 / 24.04 LTS)
# Installs Java 11, Hadoop 3.3.6 (pseudo-distributed), and MongoDB Community
# ==============================================================================

set -e

echo "=== [1/5] Updating packages and installing prerequisites ==="
sudo apt-get update
sudo apt-get install -y openjdk-11-jdk ssh pdsh wget curl gnupg tar

# Check Java
java -version

echo "=== [2/5] Configuring SSH for Hadoop ==="
# Hadoop pseudo-distributed mode requires passwordless SSH to localhost
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -P "" -f ~/.ssh/id_rsa
fi
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 0600 ~/.ssh/authorized_keys
ssh-keyscan -H localhost >> ~/.ssh/known_hosts 2>/dev/null || true
ssh-keyscan -H 0.0.0.0 >> ~/.ssh/known_hosts 2>/dev/null || true

# Test SSH connection
ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost echo "SSH localhost success"

echo "=== [3/5] Installing Apache Hadoop 3.3.6 ==="
HADOOP_VERSION="3.3.6"
HADOOP_TAR="hadoop-${HADOOP_VERSION}.tar.gz"
HADOOP_DIR="/opt/hadoop"

if [ ! -d "$HADOOP_DIR" ]; then
    echo "Downloading Hadoop ${HADOOP_VERSION}..."
    wget -q --show-progress "https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_TAR}"
    sudo tar -xzf "$HADOOP_TAR" -C /opt/
    sudo mv "/opt/hadoop-${HADOOP_VERSION}" "$HADOOP_DIR"
    sudo chown -R "$USER":"$USER" "$HADOOP_DIR"
    rm -f "$HADOOP_TAR"
    echo "Hadoop installed at $HADOOP_DIR"
else
    echo "Hadoop already installed at $HADOOP_DIR"
fi

# Detect JAVA_HOME
DETECTED_JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:/bin/java::")
echo "Detected JAVA_HOME: $DETECTED_JAVA_HOME"

# Add environment variables to ~/.bashrc if not already present
if ! grep -q "HADOOP_HOME" ~/.bashrc; then
    echo "Configuring ~/.bashrc with Hadoop & Java environment variables..."
    cat <<EOT >> ~/.bashrc

# HireTrend: Hadoop & Java Environment
export JAVA_HOME=${DETECTED_JAVA_HOME}
export HADOOP_HOME=/opt/hadoop
export HADOOP_INSTALL=\$HADOOP_HOME
export HADOOP_MAPRED_HOME=\$HADOOP_HOME
export HADOOP_COMMON_HOME=\$HADOOP_HOME
export HADOOP_HDFS_HOME=\$HADOOP_HOME
export YARN_HOME=\$HADOOP_HOME
export HADOOP_COMMON_LIB_NATIVE_DIR=\$HADOOP_HOME/lib/native
export PATH=\$PATH:\$HADOOP_HOME/sbin:\$HADOOP_HOME/bin:\$JAVA_HOME/bin
EOT
fi

# Export for current script execution
export JAVA_HOME=${DETECTED_JAVA_HOME}
export HADOOP_HOME=/opt/hadoop
export PATH=$PATH:$HADOOP_HOME/sbin:$HADOOP_HOME/bin:$JAVA_HOME/bin

# Set JAVA_HOME in hadoop-env.sh
sed -i "s|# export JAVA_HOME=.*|export JAVA_HOME=${DETECTED_JAVA_HOME}|" "$HADOOP_DIR/etc/hadoop/hadoop-env.sh"
if ! grep -q "export JAVA_HOME" "$HADOOP_DIR/etc/hadoop/hadoop-env.sh"; then
    echo "export JAVA_HOME=${DETECTED_JAVA_HOME}" >> "$HADOOP_DIR/etc/hadoop/hadoop-env.sh"
fi

# Configure core-site.xml
cat <<EOF > "$HADOOP_DIR/etc/hadoop/core-site.xml"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://localhost:9000</value>
    </property>
</configuration>
EOF

# Configure hdfs-site.xml
cat <<EOF > "$HADOOP_DIR/etc/hadoop/hdfs-site.xml"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
</configuration>
EOF

echo "=== [4/5] Installing MongoDB Community Edition & mongosh ==="
# Check Ubuntu version
UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
# MongoDB 7.0 / 8.0 support
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor --yes
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

sudo apt-get update
sudo apt-get install -y mongodb-org mongodb-mongosh || {
    echo "Fallback to distro mongodb or mongosh if repo version differs..."
    sudo apt-get install -y mongodb-mongosh || true
}

sudo systemctl daemon-reload
sudo systemctl enable mongod
sudo systemctl start mongod || sudo service mongod start || true

echo "=== [5/5] Testing Services ==="
echo "Checking MongoDB status..."
sudo systemctl status mongod --no-pager || true

echo ""
echo "=========================================================="
echo "Setup script completed!"
echo "Next step: Reload your shell and format/start HDFS:"
echo "  source ~/.bashrc"
echo "  hdfs namenode -format"
echo "  start-dfs.sh"
echo "  jps"
echo "=========================================================="
