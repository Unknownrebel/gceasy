#!/bin/bash

# change args here
APPNAME=$1
XMS=$2
XMX=$3
CONFDIR="/root/gceasy/$APPNAME"

JOBLOG=`cat /usr/local/nginx/conf/sites-e*/joblog.conf | grep alias | grep -v "#"`
if [ $? != 0 ];then
    JOBLOG=`cat /usr/local/nginx/conf/sites-a*/joblog.conf | grep alias | grep -v "#"`
fi
LOGPATH=`echo $JOBLOG | awk '{print $2}' | awk -F ";" '{print $1}' | sed 's/.$//'`
LOGDIR="$LOGPATH/gclog"
[ ${LOGDIR} ] && mkdir -p $LOGDIR
chown tomcat.tomcat $LOGDIR

# check java version
JAVA_VERSION=`java -version 2>&1 | awk -F '"' '/version/ {print $2}'`

# Enable coredump
ulimit -c unlimited

## Memory Options##
MEM_OPTS="-Xms$XMS -Xmx$XMX -XX:NewRatio=1"

if [[ "$JAVA_VERSION" < "1.8" ]]; then
    MEM_OPTS="$MEM_OPTS -XX:PermSize=128m -XX:MaxPermSize=512m"
else
    MEM_OPTS="$MEM_OPTS -XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=512m"
fi

# 启动时预申请内存
MEM_OPTS="$MEM_OPTS -XX:+AlwaysPreTouch"

# 如果线程数较多，函数的递归较少，线程栈内存可以调小节约内存，默认1M
#MEM_OPTS="$MEM_OPTS -Xss256k"

# 堆外内存的最大值默认约等于堆大小，可以显式将其设小，获得一个比较清晰的内存总量预估
#MEM_OPTS="$MEM_OPTS -XX:MaxDirectMemorySize=2g"

# 根据JMX/VJTop的观察，调整二进制代码区大小避免满了之后不能再JIT，JDK7/8，是否打开多层编译的默认值都不一样
#MEM_OPTS="$MEM_OPTS -XX:ReservedCodeCacheSize=240M"

## GC Options##
GC_OPTS="-XX:+UseConcMarkSweepGC -XX:CMSInitiatingOccupancyFraction=75 -XX:+UseCMSInitiatingOccupancyOnly"

# System.gc() 使用CMS算法
GC_OPTS="$GC_OPTS -XX:+ExplicitGCInvokesConcurrent"

# CMS中的下列阶段并发执行
#GC_OPTS="$GC_OPTS -XX:+ParallelRefProcEnabled -XX:+CMSParallelInitialMarkEnabled"

# 根据应用的对象生命周期设定，减少事实上的老生代对象在新生代停留时间，加快YGC速度
#GC_OPTS="$GC_OPTS -XX:MaxTenuringThreshold=3"

# 如果OldGen较大，加大YGC时扫描OldGen关联的卡片，加快YGC速度，默认值256较低
#GC_OPTS="$GC_OPTS -XX:+UnlockDiagnosticVMOptions -XX:ParGCCardsPerStrideChunk=1024"

# 如果JVM并不独占机器，机器上有其他较繁忙的进程在运行，将GC线程数设置得比默认值(CPU核数＊5/8 )更低以减少竞争，反而会大大加快YGC速度
# 另建议CMS GC线程数简单改为YGC线程数一半
#GC_OPTS="$GC_OPTS -XX:ParallelGCThreads=12 -XX:ConcGCThreads=6"

# 如果CMS GC时间很长，并且明显受新生代存活对象数量影响时打开，但会导致每次CMS GC与一次YGC连在一起执行，加大了事实上JVM停顿的时间
#GC_OPTS="$GC_OPTS -XX:+CMSScavengeBeforeRemark"

# 如果永久代使用不会增长，关闭CMS时ClassUnloading，降低CMS GC时出现缓慢的几率
#if [[ "$JAVA_VERSION" > "1.8" ]]; then
#    GC_OPTS="$GC_OPTS -XX:-CMSClassUnloadingEnabled"
#fi

## GC log Options, only for JDK7/JDK8 ##
LOGFILE=${LOGDIR}/gc-${APPNAME}.log

# 打印GC日志，包括时间戳，晋升老生代失败原因，应用实际停顿时间(含GC及其他原因)
GCLOG_OPTS="-Xloggc:${LOGFILE} -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintPromotionFailure -XX:+PrintGCApplicationStoppedTime"

# 打印GC原因，JDK8默认打开
if [[ "$JAVA_VERSION" < "1.8" ]]; then
    GCLOG_OPTS="$GCLOG_OPTS -XX:+PrintGCCause"
fi

# 打印GC前后的各代大小
#GCLOG_OPTS="$GCLOG_OPTS -XX:+PrintHeapAtGC"

# 打印存活区每段年龄的大小
#GCLOG_OPTS="$GCLOG_OPTS -XX:+PrintTenuringDistribution"

# 如果发生晋升失败，观察老生代的碎片
#GCLOG_OPTS="$GCLOG_OPTS -XX:+UnlockDiagnosticVMOptions -XX:PrintFLSStatistics=2"

# 打印安全点日志，找出GC日志里非GC的停顿的原因
#GCLOG_OPTS="$GCLOG_OPTS -XX:+PrintSafepointStatistics -XX:PrintSafepointStatisticsCount=1 -XX:+UnlockDiagnosticVMOptions -XX:-DisplayVMOutput -XX:+LogVMOutput -XX:LogFile=/dev/shm/vm-${APPNAME}.log"

## Optimization Options##
OPTIMIZE_OPTS="-XX:-UseBiasedLocking -XX:AutoBoxCacheMax=20000 -Djava.security.egd=file:/dev/./urandom"

# 关闭PerfData写入，避免高IO场景GC时因为写PerfData文件被阻塞，但会使得jstats，jps不能使用
#OPTIMIZE_OPTS="$OPTIMIZE_OPTS -XX:+PerfDisableSharedMem"

# 关闭多层编译，减少应用刚启动时的JIT导致的可能超时，以及避免部分函数C1编译后最终没被C2编译，但导致函数没有被初始C1编译
#if [[ "$JAVA_VERSION" > "1.8" ]]; then
#    OPTIMIZE_OPTS="$OPTIMIZE_OPTS -XX:-TieredCompilation"
#fi

# 如果希望无论函数的热度如何，最终JIT所有函数，关闭GC时将函数调用次数减半
#OPTIMIZE_OPTS="$OPTIMIZE_OPTS -XX:-UseCounterDecay"

## Trouble shooting Options##
#SHOOTING_OPTS="-XX:+PrintCommandLineFlags -XX:-OmitStackTraceInFastThrow -XX:ErrorFile=${LOGDIR}/hs_err_%p.log"

# OOM时进行HeapDump，但此时会产生较高的连续IO，如果是容器环境，有可能会影响他的容器
#SHOOTING_OPTS="$SHOOTING_OPTS -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${LOGDIR}/"

# async-profiler 火焰图效果更好的参数
#SHOOTING_OPTS="$SHOOTING_OPTS -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints"

# 在非生产环境，打开JFR进行性能记录（生产环境要收License的哈）
#SHOOTING_OPTS="$SHOOTING_OPTS -XX:+UnlockCommercialFeatures -XX:+FlightRecorder -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints"

## JMX Options##
# 开放JMX访问，设定端口号
JMX_OPTS="-Djava.rmi.server.hostname=127.0.0.1 -Dcom.sun.management.jmxremote.port=7001 -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false"

## All together ##
OPTS="JAVA_OPTS=\"$MEM_OPTS $GC_OPTS $GCLOG_OPTS $OPTIMIZE_OPTS $JMX_OPTS\""
echo $OPTS > $CONFDIR/setopts.log

# 修改应用启动脚本
SHFILE="/usr/local/$APPNAME/bin/catalina.sh"
if [[ -z `grep "JAVA_OPTS=\"-" $SHFILE` ]];then
    sed -i "/Licensed/i\\$OPTS" $SHFILE
else
    sed -i '/JAVA_OPTS=\"-/d' $SHFILE
    sed -i "/Licensed/i\\$OPTS" $SHFILE
fi

# 修改配置文件的日志路径
GCLOGFILE=`awk '/Xloggc/ {print}' $SHFILE | awk -F '-Xloggc:' '{print $2}' | awk -F'[ "]' '{print $1}'`
echo $GCLOGFILE >> $CONFDIR/setopts.log

CONFFILE="$CONFDIR/logpath.conf"
if [[ -z `grep "path" $CONFFILE` ]];then
    echo "path=$GCLOGFILE" >> $CONFFILE
else
    sed -i "s!^path.*!path=$GCLOGFILE!" $CONFFILE
fi

# 配置计划任务，定时执行
echo "1 3 * * * /usr/bin/python $CONFDIR/sendmail.py >> $CONFDIR/crontab.log" >> /var/spool/cron/root
/etc/init.d/crond reload > /dev/null 2>&1