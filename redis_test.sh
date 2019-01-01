on_node0=0,1,2,6,7,8,12,13,14,18,19,20,48,49,50,54,55,56,60,61,62,66,67,68
#redis running on 3 in node1
on_node1=4,5,9,10,11,15,16,17,21,22,23,51,52,53,57,58,59,63,64,65,69,70,71
on_node2=24,25,26,30,31,32,36,37,38,42,43,44,72,73,74,78,79,80,84,85,86,90,91,92
on_node3=27,28,29,33,34,35,39,40,41,45,46,47,75,76,77,81,82,83,87,88,89,93,94,95

function on_sameNode()
{
file=redis_scN1.txt
rm -rf $file
echo Running Server/N1 Client/N1
echo "`lscpu | grep Model`" >$file
for i in $(seq 0 2 20)
do 
	echo "Running $i parallel clients" 
	echo -e "\n $i Parallel Clients" >> $file

	numactl -C $on_node1 -l redis-benchmark -n 600000 -c $i -t get,set -q >> $file
done
}

function on_differentNode()
{
file2=redis_sN1_cN2.txt
rm -rf $file2
echo Running Server/N1 Client/N2
echo "`lscpu | grep Model`" >$file2
for i in $(seq 0 2 20)
do 
	echo "Running $i parallel clients" 
	echo -e "\n $i Parallel Clients" >> $file2

	numactl -C $on_node2 -l redis-benchmark -n 600000 -c $i -t get,set -q >> $file2
done
}

#on_sameNode
on_differentNode
