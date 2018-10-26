#!/bin/bash

# GLOBAL VALUES
ncpus=`nproc`

function install_mysql()
{
  #echo -e "Install MySQL?(y/n):\n"
  #read op
  which mysql > /dev/null 2>&1
  if [ "$?" = "0" ]; then
    echo -e "MySQL Already installed.\n"
  else
    echo -e "Installing MySQL..."
    wget https://dev.mysql.com/get/mysql-apt-config_0.8.10-1_all.deb
    sudo dpkg -i mysql-apt-config*
    sudo apt update

    echo Installing MySQL...
    sudo apt-get -y install mysql-server
    
    #echo "Now you can check the status of the mysql server using: sudo service mysql status.\n"
    which mysql
    if [ "$?" = "0" ];then
      echo -e "Creating user: 'rakesh' and granting privilages"
      mysql -u root -p root@123 -e "create user 'rakesh'@'localhost' identified with mysql_native_password by 'rakesh123';"
      mysql -u root -p root@123 -e "grant all privileges on * . * to 'rakesh'@'localhost';"
      if [ "$?" != "0" ]; then
        echo -e "Error while creating user.\nPlease login to root on nother terminal and run following commands in it:\n"
        echo "create user 'rakesh'@'localhost' identified with mysql_native_password by 'rakesh123';"
        echo "grant all privileges on * . * to 'rakesh'@'localhost';"
        echo "After above commands you can run the sysbench MySQL benchmark.\n"
        exit
      fi
      # mysql -u root -p root@123 -e "grant all privileges on * . * to 'rakesh'@'localhost';"
    fi

    #sudo systemctl status mysql
  fi
}

function install_sysbench()
{
  apt -y install make automake libtool pkg-config libaio-dev
  # For MySQL support
  apt -y install libmysqlclient-dev libssl-dev
  # For PostgreSQL support
  apt -y install libpq-dev
  
  echo "Downloading source..."
  git clone --recursive https://github.com/akopytov/sysbench.git
  
  echo "Building sysbench"
  cd sysbench
  ./autogen.sh
  # Add --with-pgsql to build with PostgreSQL support
  ./configure
  make -j8
  sudo make install
}

function new_sysbench_quick_install()
{
  which sysbench > /dev/null 2>&1
  if [ "$?" = "0" ]; then
    echo -e "\nSysbench Already installed.\n`sysbench --version`"
  else
    echo -e "Installing Sysbench 1.0...\n"
    sudo apt-get install curl -y
    curl -s https://packagecloud.io/install/repositories/akopytov/sysbench/script.deb.sh | sudo bash
    sudo apt-get -y install sysbench
  fi
}

# This function only works for sysbench version: 0.4.12
function old_sysbench_tests()
{
  echo which test to perform?
  echo -e "1. CPU \n2. MEMORY"
  echo Enter:
  read op
  if [ "$op" = "1" ]; then
    echo Running CPU Workload Benchmark...
    outfile=sysbench_cpu.txt
    init=10000
    
     rm -rf $outfile
    
    st=$SECONDS
    for((mx=$init; mx<=$init*10; mx*=2))
    do
      for((th=2; th<=$ncpus; th*=2))
      do
        echo "\nRunning for PR: $mx TH: $th Configuration"
        echo PR:$mx TH:$th >> $outfile
        sysbench --test=cpu --cpu-max-prime=$mx --num-threads=$th run >> $outfile
      done
    done
    en=$SECONDS
    
    echo Elapsed Time: $((en-st)) >> $outfile
    
  elif [ "$op" = "2" ]; then
    echo Running MEMORY Workload Benchmark...
    outfile=sysbench_memory.txt
    
    init=10000
    
    # Trying to allocate memory more than L3 Cache and stretch to RAM
    memload=250M
    totalmem=100G
    
    rm -rf $outfile
    
    st=$SECONDS
    for((th=2; th<=$ncpus; th*=2))
    do
        echo "Running with MEMLOAD: $memload, TOTALMEM: $totalmem, THREADS: $th"
        echo TH:$th >> $outfile
        # --memory-scope=global/local --memory-oper=read/write/none
        sysbench --test=memory --memory-block-size=$memload --memory-total-size=$totalmem --memory-scope=global --memory-oper=read --num-threads=$th run >> $outfile
    done
    en=$SECONDS
    
    echo Elapsed Time: $((en-st)) >> $outfile
  fi
}

# This function only works for sysbench version: 1.0
function new_sysbench_tests()
{
  echo which test to perform?
  echo -e "1. CPU \n2. MEMORY \n3. MYSQL"
  echo Enter:
  read op
  if [ "$op" = "1" ]; then
    echo Running CPU Workload Benchmark...
    outfile=sysbench_cpu.txt
    init=10000
    
     rm -rf $outfile
    
    st=$SECONDS
    for((mx=$init; mx<=$init*10; mx*=2))
    do
      for((th=2; th<=$ncpus; th+=2))
      do
        echo "\nRunning for PR: $mx TH: $th Configuration"
        echo PR:$mx TH:$th >> $outfile
        sysbench cpu --cpu-max-prime=$mx --threads=$th run >> $outfile
      done
    done
    en=$SECONDS
    
    echo Elapsed Time: $((en-st)) >> $outfile
    
  elif [ "$op" = "2" ]; then
    echo Running MEMORY Workload Benchmark...
    outfile=sysbench_memory.txt
    
    init=10000
    
    # Trying to allocate memory more than L3 Cache and stretch to RAM
    memload=250M
    totalmem=100G
    
    rm -rf $outfile
    
    st=$SECONDS
    for((th=2; th<=$ncpus; th+=2))
    do
        echo "Running with MEMLOAD: $memload, TOTALMEM: $totalmem, THREADS: $th"
        echo TH:$th >> $outfile
        # --memory-scope=global/local --memory-oper=read/write/none
        sysbench memory --memory-block-size=$memload --memory-total-size=$totalmem --memory-scope=global --memory-oper=read --num-threads=$th run >> $outfile
    done
    en=$SECONDS
    
    echo Elapsed Time: $((en-st)) >> $outfile
  elif [ "$op" = "3" ];then
    echo -e "\nRunning SQL Benchmark..."
    outfile=sysbench_mysql.txt
    rm -rf $outfile
    
    ntables=10
    
    echo "Preparing Database for benchmarking..."
    echo -e "Creating $ntables ..."
    sysbench oltp_read_write --db-driver=mysql --mysql-user=rakesh --mysql-password=rakesh123 --tables=$ntables --table-size=1000000 --threads=$ntables prepare
    
    st=$SECONDS
    # Insert only
    # sysbench /usr/share/sysbench/oltp_insert.lua --db-driver=mysql --mysql-user=root --mysql-password='' --mysql-host=127.0.0.1 --mysql-port=3310 --report-interval=2 --tables=8 --threads=8 --time=60 run
    
    # Write only
    # sysbench /usr/share/sysbench/oltp_write_only.lua --db-driver=mysql --mysql-user=root --mysql-password='' --mysql-host=127.0.0.1 --mysql-port=3310  --report-interval=2 --tables=8 --threads=8 --time=60 run
    
    for((th=2; th<=$ncpus; th+=2))
    do
      echo "Running SQL Read only Benchmark with TH: $th"
      sysbench oltp_read_only --threads=$th --mysql-user=rakesh --mysql-password=rakesh123 --tables=10 --table-size=1000000 --histogram=on --time=300 run >> $outfile
    done
    en=$SECONDS
    echo $((en-st)) >> $outfile
    
  fi
}

install_mysql
#install_sysbench
# OR
new_sysbench_quick_install

# Before running Sysbench test
# create a user in mysql and use legacy password authentication method with following command
# Ex: CREATE USER 'username’@‘localhost’ IDENTIFIED WITH mysql_native_password BY ‘password’;
new_sysbench_tests
