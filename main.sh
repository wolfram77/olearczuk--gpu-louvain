#!/usr/bin/env bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=64
#SBATCH --exclusive
#SBATCH --job-name slurm
#SBATCH --output=slurm.out
# module load openmpi/4.1.5
# module load hpcx-2.7.0/hpcx-ompi
# source scl_source enable gcc-toolset-11
# source /opt/rh/gcc-toolset-13/enable
# module load cuda/12.3
src="olearczuk--gpu-louvain"
out="$HOME/Logs/$src$1.log"
ulimit -s unlimited
printf "" > "$out"

# Download program
if [[ "$DOWNLOAD" != "0" ]]; then
  rm -rf $src
  git clone https://github.com/wolfram77/$src
  cd $src
fi

# Build program
cd ..
gvemu="gve-make-undirected"
if [ ! -d "$gvemu.sh" ]; then
  git clone https://github.com/ionicf/$gvemu.sh
  cd "$gvemu.sh"
  DOWNLOAD=0 RUN=0 ./main.sh
  cd ..
fi
cd $src
cp ../$gvemu.sh/a.out $gvemu
make all
if [[ "$?" != "0" ]];   then exit 1; fi
if [[ "$RUN" == "0" ]]; then exit 0; fi

# Make graph symmetric, and run gpulouvain
runGpuLouvain() {
  # $1: input file name (without extension)
  # $2: is graph weighted (0/1)
  # $3: is graph symmetric (0/1)
  opt2=""
  opt3=""
  if [[ "$2" == "1" ]]; then opt2="-w"; fi
  if [[ "$3" == "1" ]]; then opt3="-s"; fi
  stdbuf --output=L printf "Converting $1 to $1.undirected ...\n"                            | tee -a "$out"
  stdbuf --output=L ./gve-make-undirected -i "$1" -o "$1.undirected" -t "$opt2" "$opt3" 2>&1 | tee -a "$out"
  stdbuf --output=L ./gpulouvain -f "$1.undirected" -g 0.000001                         2>&1 | tee -a "$out"
  stdbuf --output=L printf "\n\n"                                                            | tee -a "$out"
  rm -rf "$1.undirected"
}

# Run on each graph
runEach() {
# runGpuLouvain ~/Data/web-Stanford.mtx   0 0
runGpuLouvain ~/Data/indochina-2004.mtx  0 0
runGpuLouvain ~/Data/uk-2002.mtx         0 0
runGpuLouvain ~/Data/arabic-2005.mtx     0 0
runGpuLouvain ~/Data/uk-2005.mtx         0 0
runGpuLouvain ~/Data/webbase-2001.mtx    0 0
runGpuLouvain ~/Data/it-2004.mtx         0 0
runGpuLouvain ~/Data/sk-2005.mtx         0 0
runGpuLouvain ~/Data/com-LiveJournal.mtx 1 0
runGpuLouvain ~/Data/com-Orkut.mtx       1 0
runGpuLouvain ~/Data/asia_osm.mtx        1 0
runGpuLouvain ~/Data/europe_osm.mtx      1 0
runGpuLouvain ~/Data/kmer_A2a.mtx        1 0
runGpuLouvain ~/Data/kmer_V1r.mtx        1 0
}

# Run 5 times
for i in {1..5}; do
  runEach
done

# Signal completion
curl -X POST "https://maker.ifttt.com/trigger/puzzlef/with/key/${IFTTT_KEY}?value1=$src$1"
