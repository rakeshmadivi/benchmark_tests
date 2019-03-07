#!/bin/bash
#set -x

# TESTS TO BE PERFORMED
# 	0		1
TESTS=("IOPS TEST" "THROUGHPUT TEST")

show_tests()
{
	echo Possible Tests: 
	for i in "${!TESTS[@]}"
	do
		echo $((i+1)) ${TESTS[$i]}
	done
}

die() {
	echo "Error: " $@
	show_tests
	
	echo "Eg: $0 /dev/<blockdev> 1	- For IOPS Test"
	exit 1
}

[ $# -ne 2 ] && die "Not enough arguments passed. Pass disk and test_id as arguments. "

test_file=$1

[ ! -b $test_file ] && die "$test_file is not a valid block device. Pass '/dev/<block dev>'"

window_size=5

# HOW LONG WE WANT TO RUN EACH TEST COMBINATION
run_time=1s

# Initial status for steady state
STATUS=N

echo -e "TESTING: ${test_file} \nConsidering WINDOW_SIZE: $window_size";sleep 1;

prep_result=prep_result.json

# FILES TO BE WRITTEN AND READ

# FILE TO STORE ALL TESTING RESULT
datafile=all_data.txt
olddf=old.${datafile}

# SUM FILE
sumfile=sum_ss_window.txt
oldsf=old.${sumfile}

# FILE TO STORE ONLY WRITES
writesfile=onlywrites.txt
oldwf=old.${writesfile}

# FILE TO STORE AVG OF ALL ROUNDS
avgfile=all_averages.txt
oldaf=old.${avgfile}

# FILE TO STORE CSV DATA
forexcel=iops_measurement_window_tabular_data.csv
oldexcel=old.${forexcel}

# FILE TO STORE ONLY 100% WRITES FOR EACH BLOCK IN ALL ROUNDS
w100percent=iops_ss_convergence_report.csv

# 3rd Plot
ss_4k_plot=iops_ss_measurement_window_plot.csv

# Steady State log
sslog=steadystate.log
# File to store intermediate Y values,bestfit slope,bestfit const,min,max,range,avg values.
ydata_file=ydata.txt

######################## WORK & RESULTS DIRECTORIES ###############
# Work Directory
work_dir=$PWD

todotest=`if [ $2 -eq 1 ];then echo iops;elif [ $2 -eq 2 ];then echo tp;fi`_run_

# Current Run Directory
run_n=`ls -d ${todotest}* > /dev/null 2>&1 && ls -d ${todotest}* | wc -w`
run_dir=${todotest}$((run_n + 1))

# Get end value for renaming run folder after run according to the test.
#endval=$(echo ${run_dir#*_})
#trimn=$(echo ${endval}|tr -d '\n'|wc -c)

# Create run directory
echo Creating Run Directory: $run_dir
mkdir -p $run_dir
cd $run_dir

# JSON Results
json_dir=json_results
mkdir -p ${json_dir}

#out_dir=results
#mkdir -p $out_dir

################## EXECUTION LOG #############
# Run log
runlog=run.log
date > $runlog

####################### THROUGHPUT FILES #############
# FILES		0	1		2		3		4				5		6
tp_files=(tp_data.txt tp_writes.txt tp_reads.txt tp_average.txt tp_ss_convergence.csv tp_ss_measurement_window.csv tp_measurement_window_tabular_data.csv )

aggrlog=aggr_values.log
echo "" > $aggrlog

##################################### TEST CONDITIONS/PARAMETERS SETTING ################################
# Test Conditions
# Disable volatile cache using direct=1, non-buffered io
DIRECT=1

# thread_count
NUMJOBS=4

# Data Pattern: random, operator

# FOR PREP STEP
RW=write  # Sequential read write
# For PREP STEP
bs=128k

# FOR TESTING STEP
rw_type=randrw

IOENGINE=libaio
    
# Capacity 2X, BlockSize=128KiB, sequential write file_service_type=sequential
block_size=$(cat /sys/block/${test_file/\/dev\//}/size)
#size=$(( (($block_size * 512) / 1024 / 1024 / 1024 )  * 2 ))G
size=10M #4G
echo BLOCK_SIZE: $size

test -z `which jq` && echo "Installing 'jq' package..." && sudo apt-get install jq -y

#################################### FUNCTIONS #############################################
logit()	# $1: Module name, $2: Text to print
{
	echo "[`date`] $1 : $2" >> $runlog	
}

function clear_ssd()
{
	blkdiscard
}

####################### CHECK SS CONDITIONS ####################
# Arguments: $1:Y2 values, $2:Round
function check_ss_conditions()
{
	[ $# -eq 0 ] || [ "$1" = "" ] || [ "$2" = ""  ]
	if [ $? -eq 0 ];then logit "CHECK_SS_CONDITIONS" "Error: Invalid Argumets" ;echo No/Empty Arguments passed.;exit;fi

	y=(`echo ${1}|sed 's/"//g'`)
	
	ymean=$(echo "scale=2;$ysum / ${#y[@]}" | bc)
	
	# CONDITIONS TO CHECK
	maxY=${y[0]}	minY=${y[0]}
	
	for i in `seq 1 $((${#y[@]}-1))`;do 
		minY=$(awk -v n1="$minY" -v n2="${y[$i]}" 'BEGIN{ if(n2 < n1){print n2}else{print n1} }')
		maxY=$(awk -v n1="$maxY" -v n2="${y[$i]}" 'BEGIN{ if(n2 > n1){print n2}else{print n1} }')
	done;
	echo maxY:$maxY minY:$minY;

	#let rangeY=$maxY-$minY
	rangeY=`echo "$maxY-$minY"|bc`
	echo rangeY: $rangeY

	echo Round Y Bestfit-slope Bestfit-const MinY MaxY rangeY YMean >> ${ydata_file}
	echo SS@$2 [`echo ${1}|sed 's/ /,/g'`] $BEST_SLOPE $BEST_CONST $minY $maxY $rangeY $ymean >> ${ydata_file}
	
	logit "CHECK_SS_CONDITION" "Round Y Bestfit-slope Bestfit-const MinY MaxY rangeY YMean"
	logit "CHECK_SS_CONDITOIN" "SS@$2 [`echo ${1}|sed 's/ /,/g'`] $BEST_SLOPE $BEST_CONST $minY $maxY $rangeY $ymean"

	export STATUS=`awk -v rangey="$rangeY" -v avgy="$ymean" -v slopey="$slope" 'BEGIN{ if( (rangey < 0.2*avgy) && (slopey < 0.1*avgy)){print "Y"} else{print "N"}  }'`

	[ "$STATUS" = "Y"  ]
	if [ $? -eq 0 ];then echo STEADY STATE REACHED IN ROUND-$2;fi
}

######################## BEST-FIT FUNCTION ##############
function bestfit(){

	[ $# -eq 0 ] || [ "$1" = "" ] || [ "$2" = ""  ]
	if [ $? -eq 0 ];then logit "BEST_FIT" "Error: Invalid Arguments( Arg1: $1 Arg2: $2 )";echo No/Empty Arguments passed.;exit;fi
	echo Calculating Bestfit...
	x=(`echo $1|sed 's/"//g'`)
	y=(`echo $2|sed 's/"//g'`)

	[ ${#x[@]} -ne 5 ] && [ ${#y[@]} -ne 5 ] && echo "Invalid Input X,Y sizes" && exit;
	#echo Recieved Input:
	#echo X2: ${x[@]}
	#echo Y2: ${y[@]}

	xtot=0
	ytot=0
	#for i in ${!x[@]};do let xtot+=${x[$i]};done
	#for i in ${!y[@]};do let ytot+=${y[$i]};done
	for i in ${!x[@]};do xtoto=$(echo "${xtot}+${x[$i]}" | bc );done
	for i in ${!y[@]};do ytot=$(echo "${ytot}+${y[$i]}" | bc );done
	echo xtot: $xtot ytot: $ytot
		
	declare -a dA
	declare -a dB
	xsum=$xtot	#$(echo ${x[@]}| awk '{for(i=1;i<=NF;i++){sum+=$i}{print sum}}')
	ysum=$ytot	#$(echo ${y[@]}| awk '{for(i=1;i<=NF;i++){sum+=$i}{print sum}}')
	xmean=$(echo "scale=2;$xsum / ${#x[@]}" | bc)
	ymean=$(echo "scale=2;$ysum / ${#y[@]}" | bc)
	for i in ${!x[@]} ; do
		a=$(echo "scale=2;${x[$i]}-$xmean" | bc)
		b=$(echo "scale=2;${y[$i]}-$ymean" | bc)
		v1=$(echo "scale=2;$a * $b" | bc) #awk '{print $1 * $2}')
		#v1=$(echo $a * $b | awk '{print $1 * $2}')
		v2=$(echo "scale=2; (${x[$i]} - $xmean)^2" | bc)	#awk '{print ($1 - $2)**2}')
		dA[${#dA[@]}]=$v1
		dB[${#dB[@]}]=$v2
	done
	#
	#echo dA: ${dA[@]}
	#echo dB: ${dB[@]}

	mul=$(echo ${dA[@]}|sed 's/ /+/g'|bc) #$(dtot=0;for i in ${!dA[@]};do let dtot+=${dA[$i]};done;echo $dtot) 	#$(echo ${!dA[@]} | awk '{for(i=1;i<=NF;i++){sum+=$i} {print sum}}')
	xmeansq=$(echo ${dB[@]}|sed 's/ /+/g'|bc) 	#$(echo ${dB[@]} | awk '{for(i=1;i<=NF;i++){sum+=$i} {print sum}}')

	#echo CALCULATED: mul=$mul xmeansq:$xmeansq
	slope=$(echo "$mul $xmeansq" | awk '{printf "%f\n", $1/$2}')
	yinter=$(echo "$ymean $slope $xmean" | awk '{printf "%f\n", $1 - ($2 * $3)}')
	
	echo SLOPE:$slope CONST:$yinter
	logit "BEST_FIT" "SLOPE:$slope CONST:$yinter"

	# Exporting SLOPE and CONSTANT of BESTFIT CURVE
	export BEST_SLOPE=$slope; export BEST_CONST=$yinter;
}

#bestfit

########################### CHECK STEADY STATE #######################
# Arguments to the fuction would be: rwmix% blksize round datafile
function check_steady_state()
{
	end_iter=$3
	from=$((window_size-1))
	#vals=temp.txt #temp_${1}_${2}_ENDS${end_iter}.txt
	echo #END ITERATION: $end_iter

	window=`seq $((end_iter-from)) $end_iter`
	echo Checking STEADY STATE for [ $1 $2 ] in WINDOW: ${window};sleep 1
	
	rf=$4	#$datafile
	grepexpr=$(echo `for i in $window ;do echo "$1 $2 $i|";done`|sed -e 's/| /|^/g') #^100 4k 2|100 4k 3|100 4k 4"
	#echo CHECK STRING: $grepexpr
	check=${grepexpr::-1}

	#egrep "^[0] 128k 1|^[0] 128k 2|^[0] 128k 3|^[0] 128k 4|^[0] 128k 5" 
	check2=$(echo $check|sed 's/|/|^/g')
	echo check2: $check2

	echo Checking: $check
	export SS_WINDOW=$check

	echo Retrieving X and Y Coordinates...
	#set -x
	# Read Iteration Value
	x1=$(echo `egrep "^${check2}" $rf |awk '{print $3}'`|sed -e 's/ /,/g'|tr -d ' ')
	echo CHECK: GETTING PROPER VALUES:
	echo `egrep "^${check2}" $rf |awk '{print $3}'`|sed -e 's/ /,/g'|tr -d ' '

	# Read Write Ops from datafile
	writes=$(echo `egrep "^${check2}" $rf |awk -v r=$1 '{if(r != 0)print $5;else print $4}'`|sed -e 's/ /,/g'|tr -d ' ')
	

	[ $1 -eq 0 ] && reads=$(echo `egrep "^${check2}" $rf |awk '{print $4}'`|sed -e 's/ /,/g'|tr -d ' ')
	echo Reads: $reads

	echo X1: $x1 
	echo Y1w: $writes

	# Using bestfit() function
	x2=$(echo `egrep "^${check}" $rf | awk '{print $3}'`)
	y2=$(echo `egrep "^${check}" $rf |awk -v r=$1 '{if(r != 0)print $5;else print $4}'`)
	echo -e "Input for bash_bestfit:\nX2: $x2 \nY2: $y2\n"
	bestfit "$x2" "$y2"

	# Using python script for best fit
	# IF PYTHON SCRIPT TO BE CALLED UNCOMMENT FOLLOWING 2 LINES and COMMENT THE LINE READING 'STATUS' variable.
	#python best_fit.py $x1 $writes $2
	#status=$(if [ $? -eq 0 ];then echo Y;else echo N;fi)

	# CALL STEADY STATE CONDITIONS CHECK
	check_ss_conditions "$y2" $end_iter

	# IF FOUND STEADY STATE STOP THE RUN
	if [ "$STATUS" = "Y" ]
	then
		export YDATA="$y2"; export SS_ROUND=$3;
		echo SS_ROUND: $SS_ROUND YDATA: $YDATA
		echo SS@$round [$1,$2,`echo $window|sed 's/ /-/g'`] [`echo $y2|sed 's/ /,/g'`] $BEST_SLOPE $BEST_CONST >> $sslog
		echo "Steady state reached at Round: $3 ... Stopping run now...\n"
		export STOP_NOW=y
	fi

	sleep 1
}


############################ [ IOPS TEST ] #############################
############################ IOPS POST RUN #######################
function post_run()
{
	echo -e "\nPerforming post run data formatting...\n"
	# GET ONLY WRITES
	echo Retrieving only writes...
	#awk '{if(NF==5){print $1" "$2" "$3" "$5}else{print $0}}' $datafile > $writesfile
	awk '{print $1" "$2" "$3" "$5}' $datafile > $writesfile

	# SUM: write READS+WRITES of SS WINDOW to sumfile.
	rm -rf $sumfile
	win_frm=$((SS_ROUND - $((window_size - 1))))
	for i in `seq $win_frm  $SS_ROUND`
	do
		egrep "k $i " $datafile | awk -v iter=$i '{sum=$4+$5;print $1" "$2" "$3" "sum}' >> ${sumfile}
	done

	rm -rf $w100percent

	tf=temp.txt
	rm -rf $tf

	logit "POST_RUN" "Generating SS Convergence Report."

	echo Generating Data for IOPS Steady State Convergence Plot \[All Block Sizes\]... 
	echo Round,4k,8k,16k,32k,64k,128k,1024k > $w100percent
	for i in `seq  $((SS_ROUND - $((window_size - 1)))) $SS_ROUND`
	do 
		echo -n "$i," >> $tf
		for j in 4k 8k 16k 32k 64k 128k 1024k
		do 
			echo -n `grep "^100 ${j} ${i} " $writesfile|awk '{print $4" "}'` >> $tf 
			echo -n " " >> $tf
			#echo -n `grep "^100 ${j} ${i} " $writesfile |awk '{print $4" "}'`|sed 's/ /,/g' >> $w100percent
		done
		echo >> $tf
	done

	sed -e 's/ /,/g' $tf >> $w100percent ; rm -rf $tf;


	logit "POST_RUN" "Calculating Averages of SS Window."
	echo "Calculating Average of all rounds..."
	for i in 100 95 65 50 35 5 0
	do 
		for j in 4k 8k 16k 32k 64k 128k 1024k
		do 
			echo -n "${i} ${j} " >> $avgfile 
			echo `grep "^${i} ${j} " ${sumfile} |awk '{sum+=$4} END {print sum / NR}'` >> $avgfile
		done
	done

	logit "POST_RUN" "Generating IOPS Measurement Window Tabular Data."
	echo Generating IOPS Measurement Window Tabular Data \[ All RWMix, Block Sizes \]...
	echo RW_MIX,0/100,5/95,35/65,50/50,65/35,95/5,100/0 > $forexcel
	for i in 4k 8k 16k 32k 64k 128k 1024k
	do 
		echo -n "${i}," >>$forexcel
		echo `grep " ${i} " $avgfile |awk '{print $3}'`|sed 's/ /,/g' >> $forexcel
	done

	
	logit "POST_RUN" "Generating SS Plot."
       echo "Round,100%w-IOPS,100%-Avg,110%-Avg,90%-Avg,Best_fit" >> $ss_4k_plot
       avg=$(grep -v "k" $w100percent |awk -F ',' '{sum+=$2}END{print sum/NR}')
       cnt=$win_frm #1
       best_m=$(tail -n-1 ${ydata_file} | awk '{print $3}')
       best_c=$(tail -n-1 ${ydata_file} | awk '{print $4}')

       for i in `echo  $(grep -v "k" $w100percent |awk -F ',' '{print $2}')`  #$(cut -f2 -d',' $w100percent |tail -n+2)`
       do

	       w110p=`echo "1.1 * $avg" | bc`
	       w90p=`echo "0.9 * $avg"|bc`
	       bestfit_val=$(echo "(${best_m}*${cnt})+${best_c}"|bc)	# y=mx+c
	       echo "$cnt,$i,$avg,$w110p,$w90p,${bestfit_val}" >> $ss_4k_plot
	       cnt=$((cnt+1))
       done		
}

############################## IOPS TEST ACTIVATION #############################
function ssd_iops()
{
  # For ActiveRange 0:100
    # purge
    # Run Workload Independent Pre-conditioning
      #**********************************************************************************************************#
      # Set and record test conditions
      # Disable device volatile write cache, OIO/Threads, Thread_count, Data pattern: random,operator
      # Run sequential WIPC with: 2X User capacity @128KiB SEQ Write, writing to entire LBA without restrictions.
      #**********************************************************************************************************#
	test -f $datafile && test -f $writesfile && test -f $avgfile && test -f $w100percent && test -f $forexcel && test -f $ss_4k_plot
	if [ $? -eq 1 ]	
	then
		rm -rf *.txt *.csv
	else
	      echo "Saving previous results..."
	      rm -rf old.*
	      ls *.csv *.txt|xargs -I % mv % old.%
	fi

	sleep 1

	logit "SSD_IOPS" "WIPC: Activation/Independent Pre-conditioning."
      # ACTIVATION
      echo Running Workload Independent Preconditioning...
      sudo fio --name=WIPC --filename=${test_file} --size=${size} --bs=${bs} --direct=${DIRECT} --rw=${RW} --iodepth=1 --output-format=json > $prep_result 
      
	logit "SSD_IOPS" "WDPC: Testing/Stimulus/Dependent Pre-conditioning."
      # START TESTING
	round=1
	while true
	do
	  st=$SECONDS
	  echo Running ROUND: $round

	  # CONTINUE TEST UNTIL ROUND 25
	  if [ $round -gt 25 ]
	  then
		  logit "SSD_IOPS" "Note: No Seady State found even after Round 25."
		  echo "STEADY STATE IS NOT FOUND EVEN AFTER ROUND ${round}... "
		  echo "Aborting the run...\n";exit
	  fi

	  for rwmix in 100 95 65 50 35 5 0
	  do
		for blk_size in 4k 8k 16k 32k 64k 128k 1024k
		do
			echo Running $rwmix $blk_size
			
			test_size="`echo "${size: :-1}/2"|bc``echo ${size: -1}`"

			logit "SSD_IOPS" "Testing: RWMIX-write = $rwmix Block_size = $blk_size Round = $round"
			sudo fio --name=WDPC --filename=${test_file} --size=${test_size} --bs=${blk_size} --rwmixwrite=${rwmix} --direct=${DIRECT} --rw=${rw_type} --runtime=${run_time} --iodepth=1 --output-format=json > ${json_dir}/${rwmix}_${blk_size}_result.json

			r_iops=`cat ${json_dir}/${rwmix}_${blk_size}_result.json |jq '.jobs'|jq '.[].read.iops'`
			w_iops=`cat ${json_dir}/${rwmix}_${blk_size}_result.json |jq '.jobs'|jq '.[].write.iops'`

			logit "SSD_IOPS" "r_iops: $r_iops w_iops: $w_iops"

			if [ $rwmix -eq 100 ];then
				echo "$rwmix $blk_size $round 0 $w_iops" >> $datafile 
			elif [ $rwmix -eq 0 ];then
				echo "$rwmix $blk_size $round $r_iops  0" >> $datafile
			else
				echo "$rwmix $blk_size $round $r_iops $w_iops" >> $datafile
			fi
		done
	  done
	  et=$SECONDS

	  echo Iteration: $round Elapsed Time: $((et-st)) seconds

	  if [ $round -gt $((window_size-1)) ]
	  then
		logit "SSD_IOPS" "Checking Steady State for - 100 4k $round"
		check_steady_state 100 4k $round $datafile
          fi
	  
	  if [ "$STOP_NOW" = "y" ]
	  then
		logit "SSD_IOPS" "Steady State Reached @ Round = $round"
		echo Breaking out of run loop...
		break;
  	  fi
	echo Incrementing iteration...
	round=$((round+1))

	done
      
      
    # Process and Plot the accumulated rounds data 
    echo "EXECUTION DONE."
    logit "SSD_IOPS" "Execution DONE."
}

################################################## [ THROUGHPUT TEST ]##################################################################

# TROUGHPUT POST RUN
# Arguments: rwmixwrite%
function tp_post_run()
{
	# REPORTS REQUIRED
	#: '
	#1. Purge Report
	#2. Preconditioning Report
	#3. Steady state convergence report - Write (Plot)
	#4. Steady state convergence report - Read (Plot)
	#5. Steady state verification report
	#6. steady state measurement window (Plot)
	#7. Measurement Window report (Tabular Data)
	#'

	echo -e "\nPerforming post run data formatting...\n"
	echo RWMIX: $1 BLKSIZE: $blk_size 

	rm -rf $w100percent

	tf=temp.txt
	rm -rf $tf

	w_from=$(expr $SS_ROUND - $((window_size - 1)) )
	w_seq=`seq $w_from $SS_ROUND`

	#exp1=$(echo `for i in $w_seq ;do echo "100 128k $i|";done`|sed -e 's/| /|/g') #^100 128k 2|100 128k 3|100 128k 4"
	#exp2=$(echo `for i in $w_seq ;do echo "100 1024k $i|";done`|sed -e 's/| /|/g') #^100 1024k 2|100 1024k 3|100 1024k 4"
	#grep128=${exp1::-1}
	#grep1024=${exp2::-1}
	#exit
	
	logit "TP_POST_RUN" "TP_Convergence"
	# THROUGHPUT STEADY STATE CONVERGENCE
	echo Generating THROUGHPUT STEADY STATE CONVERGENCE \[ For Read and Write Separately \]... 
	#########################
	values100=""
	values0=""
	for i in `seq $w_from $SS_ROUND`	#$(expr $SS_ROUND - $((window_size - 1))) $SS_ROUND`
	do
		
		for j in 128k 1024k
		do

			egrep "^100 $j $i" ${tp_files[0]}
			wfound=$?
			[ $wfound -eq 1 ] && values100="$values100 NA"
			[ $wfound ] && values100="$values100 `egrep "^100 $j $i" ${tp_files[0]}|awk '{print $5}'`"

			egrep "^0 $j $i" ${tp_files[0]}
			rfound=$?
			[ $rfound  -eq 1 ] && values0="$values0 NA"
			[ $rfound ] && values0="$values0 `egrep "^0 $j $i" ${tp_files[0]}|awk '{print $4}'`"
		done
		[ $1 -eq 100 ] && echo $i $values100 | sed 's/ /,/g' >> ${tp_files[1]}
		[ $1 -eq 0 ] && echo $i $values0 | sed 's/ /,/g' >> ${tp_files[2]}

		values100=""
		values0=""
	done

	echo TP_SS_Covergence-WRITE: 128k, > ${tp_files[4]}
	echo ROUND,128k >> ${tp_files[4]}
	#egrep "NA" ${tp_files[1]}| awk -F ',' '{print $1","$2}' >> ${tp_files[4]} 
	awk -F ',' '{if($3 == "NA")print $1","$2}' ${tp_files[1]} >> ${tp_files[4]} 
	
	echo TP_SS_Covergence-WRITE: 1024k, >> ${tp_files[4]}
	echo ROUND,1024k >> ${tp_files[4]}
	awk -F ',' '{if($1 != "ROUND" && $3 != "NA")print $1","$3}' ${tp_files[1]} >> ${tp_files[4]}
	
	echo TP_SS_Covergence-READ: 128k, >> ${tp_files[4]}
	echo ROUND,128k >> ${tp_files[4]}
	#egrep "NA" ${tp_files[2]}| awk -F ',' '{print $1","$2}' >> ${tp_files[4]} 
	awk -F ',' '{if($3 == "NA")print $1","$2}' ${tp_files[2]} >> ${tp_files[4]} 
	
	echo TP_SS_Covergence-READ: 1024k, >> ${tp_files[4]}
	echo ROUND,1024k >> ${tp_files[4]}
	awk -F ',' '{if($1 != "ROUND" && $3 != "NA")print $1","$3}' ${tp_files[2]} >> ${tp_files[4]}

	#########################

	logit "TP_POST_RUN" "TP_Measurement_Window_Tabular_Data"
	# AVERAGES - TP Measurement Window Tabular Data
	#########################
	echo "TP - Calculating Average of all rounds..."
	w128avg=$(awk -F ',' -v ws=$window_size '{if($3 == "NA")sum+=$2;cnt+=1}END{print sum/ws}' ${tp_files[1]})
	w1024avg=$(awk -F ',' -v ws=$window_size '{if($1 != "ROUND" && $3 != "NA")sum+=$3;cnt+=1}END{print sum/ws}' ${tp_files[1]})

	r128avg=$(awk -F ',' -v ws=$window_size '{if($3 == "NA")sum+=$2;cnt+=1}END{print sum/ws}' ${tp_files[2]})
	r1024avg=$(awk -F ',' -v ws=$window_size '{if($1 != "ROUND" && $3 != "NA")sum+=$3;cnt+=1}END{print sum/ws}' ${tp_files[2]})

	# tp_measurement_window_tabular_data.csv
	echo BLOCK_SIZE,0/100,100/0 > ${tp_files[6]}
	echo 128k,${w128avg},${r128avg} >> ${tp_files[6]}
	echo 1024k,${w1024avg},${r1024avg} >> ${tp_files[6]}

	#### Take values from steadystate.log and calculate best-fit for TP_SS_CONVEGENCE_WINDOW_PLOT
	# Returns array of bestfit values for each set

	logit "TP_POST_RUN" "TP_SS_Convergce Window"
	# TP_SS_CONVERGENCE_WINDOW_PLOT
	# 128k: WRITE & READ
	#if [  "$2" = "128k" ]
	#then
		arr=(`grep "\[100,128k," $sslog |awk '{print $2" "$4" "$5}'`); w128k=($(for i in `echo ${arr[0]}| awk -F, '{print $3}'|tr -d ']'|sed 's/-/ /g'`;do echo "$i * ${arr[1]} + ${arr[2]}"|bc;done)); echo ${w128k[@]}
		arr=(`grep "\[0,128k," $sslog |awk '{print $2" "$4" "$5}'`); r128k=($(for i in `echo ${arr[0]}| awk -F, '{print $3}'|tr -d ']'|sed 's/-/ /g'`;do echo "$i * ${arr[1]} + ${arr[2]}"|bc;done)); echo ${r128k[@]}
		echo -e "128k-WRITE,\nROUND,WRITE_TP,100%-Avg,110%-Avg,90%-Avg,Best_fit" > ${tp_files[5]}
		awk -F ',' '{if($3 == "NA")print $1","$2}' ${tp_files[1]}|awk -F',' -v w128avg=$w128avg -v bfit="$(echo ${w128k[@]})" -v id=1 '{split(bfit,bfit_arr," ");print $1","$2","w128avg","1.1*w128avg","0.9*w128avg","bfit_arr[id];id+=1}' >> ${tp_files[5]}
		echo -e "128k-READ,\nROUND,READ_TP,100%-Avg,110%-Avg,90%-Avg,Best_fit" >> ${tp_files[5]}
		awk -F ',' '{if($3 == "NA") print $1","$2}' ${tp_files[2]}| awk -F ',' -v r128avg=$r128avg -v bfit="$(echo ${r128k[@]})" -v id=1 '{split(bfit,bfit_arr," ");print $1","$2","r128avg","1.1*r128avg","0.9*r128avg","bfit_arr[id];id+=1}' >> ${tp_files[5]} 
	#fi
	
	# 1024k: WRITE & READ
	#if [  "$2" = "1024k" ]
	#then
		arr=(`grep "\[100,1024k," $sslog |awk '{print $2" "$4" "$5}'`); w1024k=($(for i in `echo ${arr[0]}| awk -F, '{print $3}'|tr -d ']'|sed 's/-/ /g'`;do echo "$i * ${arr[1]} + ${arr[2]}"|bc;done)); echo ${w1024k[@]}
		arr=(`grep "\[0,1024k," $sslog |awk '{print $2" "$4" "$5}'`); r1024k=($(for i in `echo ${arr[0]}| awk -F, '{print $3}'|tr -d ']'|sed 's/-/ /g'`;do echo "$i * ${arr[1]} + ${arr[2]}"|bc;done)); echo ${r1024k[@]}
		echo -e "1024k-WRITE,\nROUND,WRITE_TP,100%-Avg,110%-Avg,90%-Avg,Best_fit" >> ${tp_files[5]}
		awk -F ',' '{if($1 != "ROUND" && $3 != "NA")print $1","$3}' ${tp_files[1]} |awk -F ',' -v w1024avg=$w1024avg -v bfit="$(echo ${w1024k[@]})" -v id=1 '{split(bfit,bfit_arr," ");print $1","$2","w1024avg","1.1*w1024avg","0.9*w1024avg","bfit_arr[id];id+=1}' >> ${tp_files[5]}
		echo -e "1024k-READ,\nROUND,READ_TP,100%-Avg,110%-Avg,90%-Avg,Best_fit" >> ${tp_files[5]}
		awk -F ',' '{if($1 != "ROUND" && $3 != "NA")print $1","$3}' ${tp_files[2]}| awk -F ',' -v r1024avg=$r1024avg -v bfit="$(echo ${r1024k[@]})" -v id=1 '{split(bfit,bfit_arr," ");print $1","$2","r1024avg","1.1*r1024avg","0.9*r1024avg","bfit_arr[id];id+=1}' >> ${tp_files[5]}
	#fi
}

################## THROUGHPUT TEST ACTIVATION ###########
function ssd_tp()
{
  # For ActiveRange 0:100
    # purge
    # Run Workload Independent Pre-conditioning
      #**********************************************************************************************************#
      # Set and record test conditions
      # Disable device volatile write cache, OIO/Threads, Thread_count, Data pattern: random,operator
      # Run sequential WIPC with: 2X User capacity @128KiB SEQ Write, writing to entire LBA without restrictions.
      #**********************************************************************************************************#
	: '[ -f ${tp_files[0]} ] && [ -f $writesfile ] && [ -f $avgfile ] && [ -f $w100percent ] && [ -f $forexcel ] && [ -f $ss_4k_plot ]
	if [ $? -eq 1 ]	
	then
		#rm -rf *.txt *.csv
		mv *.txt *.csv save/dump/
	else
	      echo "Saving previous results..."
	      rm -rf old.*
	      ls *.txt *.csv | xargs -I % mv % old.%
	fi

	sleep 1

      
	# Remove log files
	rm -rf *.log
	'

	# THROUGHPUT SETTINGS
	tp_rwtype=rw	# Mixed sequential reads and writes

	rm -rf ${tp_files[@]}
	echo ROUND,128k,1024k | tee -a ${tp_files[1]} ${tp_files[2]}
	logit "SSD_TP" "Starting TP_Test"
	for blk_size in 128k 1024k
	do
		for rwmix in 100 0	# Read-Write Mix (0/100,100/0)
		do
			echo Running rwmix=$rwmix;
			export SS_ROUND=""
			#echo ${blk_size}_${rwmix} | tee -a ${tp_files[1]} ${tp_files[2]}
			sleep 2
			
			logit "SSD_TP" "TP_Params: BLKSIZE: $blk_size RWMIX: $rwmix"
			logit "SSD_TP" "TP_Activation"
			# ACTIVATION
			echo Running Workload Independent Preconditioning...
			sudo fio --name=WIPC --filename=${test_file} --size=${size} --bs=${blk_size} --direct=${DIRECT} --rw=write --iodepth=1 > tp_prep_result.txt 

			logit "SSD_TP" "TP_TestStimulus"
			# START TESTING
			round=1
			while true
			do
				echo Running ROUND: $round

				# CONTINUE TEST UNTIL ROUND 25
				if [ $round -gt 25 ]
				then 
					echo "STEADY STATE IS NOT FOUND EVEN AFTER ROUND $((round-1))... "

					echo "Aborting the run...\n";exit
				fi
				
				# Check STOP_NOW Status to break
				if [ "$STOP_NOW" = "y" ]
				then
					tp_post_run $rwmix $blk_size
					#reset the value before exiting.
					export STOP_NOW="n"
					echo Breaking out of run loop...
					break;
					#continue;
				fi

				echo Running $rwmix $blk_size

				test_size="`echo "${size: :-1}/2"|bc``echo ${size: -1}`"
				echo test_size:$test_size

				#output=$(echo `sudo fio --name=WDPC --filename=${test_file} --size=${test_size} --bs=${blk_size} --rwmixwrite=${rwmix} --direct=${DIRECT} --rw=${tp_rwtype} --runtime=${run_time} --iodepth=1|grep iops |cut -f3 -d ','|cut -f2 -d'='`)

				## NEW
				logit "SSD_TP" "Running BlockSize = $blk_size RWMIX-WRITE: $rwmix @ Round-$round"
				output=$(echo `sudo fio --name=WDPC --filename=${test_file} --size=${test_size} --bs=${blk_size} --rwmixwrite=${rwmix}  --rw=${tp_rwtype} --runtime=${run_time} --iodepth=1|grep aggrb |cut -f2 -d ','|cut -f2 -d'='`)

				output_val=$(echo ${output:: -4})
				units=$(echo $output| grep -o ....$)

				echo -n "$blk_size RW_MIX:${rwmix}: " >> $aggrlog

				if test $units == "MB/s"
				then
					val_inkb=$(echo "$output_val * 1024"|bc)
					output_val=$val_inkb
					echo "[${output}] $val_inkb KB/s [Converted]" >> $aggrlog
				else
					echo [${output}] $output_val $units >> $aggrlog
				fi

				logit "SSD_TP" "Value Conversion: [$output] -> [$output_val]"


				if [ $rwmix -eq 100 ];then
					echo "$rwmix $blk_size $round 0 $output_val" >> ${tp_files[0]}
				elif [ $rwmix -eq 0 ];then
					echo "$rwmix $blk_size $round $output_val  0" >> ${tp_files[0]}
				else
					echo "$rwmix $blk_size $round $output_val" >> ${tp_files[0]}
				fi

				# CHECKING STEADY STATE
				if [ $round -gt $((window_size-1)) ]
				then
					# Call function to check steady state
					logit "SSD_TP" "TP_CheckSteadyState"
					check_steady_state $rwmix $blk_size $round ${tp_files[0]}
				fi

				echo Incrementing iteration...
				round=$((round+1))
			done	# End While

	  done	# End Inner for i.e RWMIX
	  echo 'continue with next block size(y/n)?'
	  #: '
	  #read confirmation
	  confirmation="y"
	  if [ "$confirmation" = "y" ] 
	  then 
		  export STATUS=N; export STOP_NOW=n;
	  else
		  export STOP_NOW=y;break;
	  fi
	  #'
	done	# End Outer for i.e blk_size
      
    echo Moving TP Result files...
    logit "SSD_TP" "Moving TP Result files"
    #mv tp_*.csv ${out_dir}/
    
    echo "EXECUTION DONE."
    logit "SSD_TP" "Execution DONE."
}


#echo Enter the Test Number to continue: ; read opt_run

if [ $2 -eq 1  ]
then
	ssd_iops
	post_run

	# Rename the Run folder to differentiate tests
	#mv $run_dir iops_${run_dir::-${trimn}}_$((endval+1))
elif [ $2 -eq 2  ]
then
	ssd_tp
	
	# Rename the Run folder to differentiate tests
	#mv $run_dir tp_${run_dir::-${trimn}}_$((endval+1))
fi
