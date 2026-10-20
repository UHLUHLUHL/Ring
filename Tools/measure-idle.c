#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
int main(int argc,char **argv) {
 if(argc != 2) return 2;
 int pid=atoi(argv[1]); struct rusage_info_v2 before={0},after={0};
 if(proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t *)&before)) return 3;
 struct timespec pause={10,0}; nanosleep(&pause,NULL);
 if(proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t *)&after)) return 4;
 double user=(after.ri_user_time-before.ri_user_time)/1e9,system=(after.ri_system_time-before.ri_system_time)/1e9;
 printf("pid=%d interval=10s user=%.9fs system=%.9fs one_core_cpu=%.6f%% resident=%llu footprint=%llu\n",pid,user,system,(user+system)*10,after.ri_resident_size,after.ri_phys_footprint);
 return 0;
}
