# mysql is running on 24 on node2, so removed 24 from list
on_node0=0,1,2,6,7,8,12,13,14,18,19,20,48,49,50,54,55,56,60,61,62,66,67,68
on_node1=3,4,5,9,10,11,15,16,17,21,22,23,51,52,53,57,58,59,63,64,65,69,70,71
on_node2=25,26,30,31,32,36,37,38,42,43,44,72,73,74,78,79,80,84,85,86,90,91,92
on_node3=27,28,29,33,34,35,39,40,41,45,46,47,75,76,77,81,82,83,87,88,89,93,94,95

function apply_load()
{
	echo -e "Startging load on NODES: \n$1 \n$2 \n$3"
	set -x
	cd /home/aic/benchmark_tests/stream-scaling
	numactl -C $1 -l ./multi-stream-scaling 1 loadN0 &
	numactl -C $2 -l ./multi-stream-scaling 1 loadN0 &
	
	if [ "$#" = "3" ]
       	then
	numactl -C $3 -l ./multi-stream-scaling 1 loadN0 &
	fi
	cd /home/aic/benchmark_test
	set +x
}

function on_sameNode()
{
outfile=sql_pinned_scN2.txt

echo "`lscpu|grep Model`" > $outfile

echo Running scN2
for th in `seq 0 2 12`
do
	echo Running mysql read only with $th Threads
	echo -e "==== $th Threads ====" >> $outfile
	numactl -C $on_node2 --localalloc sysbench oltp_read_only --threads=$th --mysql-user=rakesh --mysql-password=rakesh123 --tables=10 --table-size=1000000 --histogram=on --time=300 run >> $outfile
done
}

function on_differentNode()
{
outfile2=sql_pinned_sN2_cN1.txt

echo "`lscpu|grep Model`" > $outfile2
echo Running sN2_cN1
for th in `seq 0 2 12`
do
	echo Running mysql read only with $th Threads
	echo -e "==== $th Threads ====" >> $outfile2
	numactl -C $on_node1 --localalloc sysbench oltp_read_only --threads=$th --mysql-user=rakesh --mysql-password=rakesh123 --tables=10 --table-size=1000000 --histogram=on --time=300 run >> $outfile2
done
}

#apply_load  $on_node0 $on_node1 $on_node3
set -x
#on_sameNode

#sudo kill -9 `pidof stream`

#apply_load $on_node0 $on_node3
set -x
on_differentNode
