#!/bin/bash
# This scripts works for sysbench version: 0.4.12
# GLOBAL VALUES
ncpus=`nproc`

function sysbench_tests()
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
      for((th=1; th<=$ncpus; th*=2))
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
    for((th=1; th<=$ncpus; th*=2))
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
