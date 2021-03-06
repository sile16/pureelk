#!/bin/bash

PUREELK_PATH=/purepoc/pureelk
PUREELK_CONF=$PUREELK_PATH/conf
PUREELK_ESDATA=/purepoc/data/esdata
PUREELK_LOG=/purepoc/logs/pureelk
PUREELK_VERSION=test
PUREELK_REPO=sile16

ELK_VERSION=6.1.2
ELASTIC_IMAGE=docker.elastic.co/elasticsearch/elasticsearch-oss:$ELK_VERSION
KIBANA_IMAGE=docker.elastic.co/kibana/kibana-oss:$ELK_VERSION

PUREELK_ES=pureelk-elasticsearch
PUREELK_KI=pureelk-kibana
PUREELK=pureelk
LOGROTATE=blacklabelops-logrotate

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PUREELK_SCRIPT_URL=https://raw.githubusercontent.com/$PUREELK_REP/pureelk/master/pureelk.sh
PUREELK_SCRIPT_LOCALPATH=$PUREELK_PATH/pureelk.sh

print_help() {
  echo "Usage: $0 {help|install [dns_ip]|start|stop|attach|delete}"
}

print_info() {
  printf "${GREEN}$1${NC}\n"
}

print_warn() {
  printf "${YELLOW}$1${NC}\n"
}

detect_distro()
{
  # init process is pid 1
  INIT=`ls -l /proc/1/exe`
  if [[ $INIT == *"upstart"* ]]; then
    SYSTEMINITDAEMON=upstart
  elif [[ $INIT == *"systemd"* ]]; then
    SYSTEMINITDAEMON=systemd
  elif [[ $INIT == *"/sbin/init"* ]]; then
    INIT=`/sbin/init --version`
    if [[ $INIT == *"upstart"* ]]; then
      SYSTEMINITDAEMON=upstart
    elif [[ $INIT == *"systemd"* ]]; then
      SYSTEMINITDAEMON=systemd
    fi
  fi

  if [ -z "$SYSTEMINITDAEMON" ]; then
    echo "WARNING: Unknown distribution, defaulting to systemd - this may fail." >&2
    SYSTEMINITDAEMON=systemd
  fi
}

config_service() {
  if [ "$SYSTEMINITDAEMON" == "systemd" ]
  then
    config_systemd
  else
    config_upstart
  fi
}

config_upstart() {
  curl -o ${PUREELK_SCRIPT_LOCALPATH} ${PUREELK_SCRIPT_URL}
  chmod u+x ${PUREELK_SCRIPT_LOCALPATH}

  cat > /etc/init/pureelk.conf << END_OF_UPSTART
  start on runlevel [2345]
  stop on [!2345]
  task
  exec ${PUREELK_SCRIPT_LOCALPATH} start
END_OF_UPSTART
}

config_systemd() {
  curl -o ${PUREELK_SCRIPT_LOCALPATH} ${PUREELK_SCRIPT_URL}
  chmod u+x ${PUREELK_SCRIPT_LOCALPATH}

  cat > /etc/systemd/system/docker-pureelk.service << END_OF_SYSTEMD

  [Unit]
  Description=pureelk container
  Requires=docker.service
  After=docker.service

  [Service]
  Type=oneshot
  ExecStart=${PUREELK_SCRIPT_LOCALPATH} start
  ExecStop=${PUREELK_SCRIPT_LOCALPATH} stop
  RemainAfterExit=yes

  [Install]
  WantedBy=default.target
END_OF_SYSTEMD

  systemctl enable docker-pureelk.service
}

install() {
  if [ "$(uname)" == "Linux" ]; then
      detect_distro

      which docker 
      if [ $? -ne 0 ]
      then
          print_warn "Docker not yet installed, installing..."
          curl -sSL https://get.docker.com/ | sh

          # For CentOS, we need to start the docker service
          if [ "$SYSTEMINITDAEMON" == "systemd" ]
          then
            systemctl start docker
            systemctl enable docker
          fi
      else
          print_info "Docker is already installed"
      fi
     
      #required for elk to work
      sysctl -w vm.max_map_count=262144
  fi

  print_info "Pulling elasticsearch image..."
  docker pull $ELASTIC_IMAGE

  print_info "Pulling kibana image..."
  docker pull $KIBANA_IMAGE

  print_info "Pulling pureelk image..."
  docker pull $PUREELK_REPO/pureelk:$PUREELK_VERSION

  print_info "Pulling logrotate image..."
  docker pull blacklabelops/logrotate

  print_info "Creating local pureelk folders at $PUREELK_PATH"

  if [ ! -d "$PUREELK_CONF" ]; then
      sudo mkdir -p $PUREELK_CONF
  fi

  if [ ! -d "$PUREELK_ESDATA" ]; then
      sudo mkdir -p $PUREELK_ESDATA
      sudo chmod 777 $PUREELK_ESDATA
  fi

  if [ ! -d "$PUREELK_LOG" ]; then
      sudo mkdir -p $PUREELK_LOG
      sudo chmod 777 $PUREELK_LOG
  fi

  config_service

  print_info "Installation complete."
}

start_containers() {
  print_info "Starting PureElk elasticsearch container..."
  if [ -n "$1" ];
  then
    DNS_ARG='--dns='$1
  else
    DNS_ARG=''
  fi
  RUNNING="$(docker inspect -f '{{.State.Running}}' $PUREELK_ES)"
  if [ $? -eq 1 ];
  then
      print_warn "$PUREELK_ES doesn't exist, starting..."
      echo docker run -d --name=$PUREELK_ES $DNS_ARG \
                 -p 9200:9200 -p 9300:9300 \
                 -e "discovery.type=single-node" \
                 --log-opt max-size=100m \
                 -v "$PUREELK_ESDATA":/usr/share/elasticsearch/data \
                 $ELASTIC_IMAGE
      docker run -d --name=$PUREELK_ES $DNS_ARG \
                 -p 9200:9200 -p 9300:9300 \
                 -e "discovery.type=single-node" \
                 --log-opt max-size=100m \
                 -v "$PUREELK_ESDATA":/usr/share/elasticsearch/data \
                 $ELASTIC_IMAGE


  elif [ "$RUNNING" == "false" ];
  then
      docker start $PUREELK_ES
  else
      print_warn "$PUREELK_ES is already running."
  fi

  print_info "Start PureElk kibana container..."
  RUNNING="$(docker inspect -f '{{.State.Running}}' $PUREELK_KI)"
  if [ $? -eq 1 ];
  then
      print_warn "$PUREELK_KI doesn't, starting..."
      docker run -d -p 5601:5601 --name=$PUREELK_KI $DNS_ARG --log-opt max-size=100m --link $PUREELK_ES:elasticsearch $KIBANA_IMAGE
  elif [ "$RUNNING" == "false" ];
  then
      docker start $PUREELK_KI
  else
      print_warn "$PUREELK_KI is already running."
  fi

  print_info "Start PureElk container..."
  RUNNING="$(docker inspect -f '{{.State.Running}}' $PUREELK)"
  if [ $? -eq 1 ];
  then
      print_warn "$PUREELK doesn't exist, starting..."
      docker run -d -p 80:8080 --name=$PUREELK $DNS_ARG --log-opt max-size=100m -v "$PUREELK_CONF":/pureelk/worker/conf -v "$PUREELK_LOG":/var/log/pureelk --link $PUREELK_ES:elasticsearch $PUREELK_REPO/pureelk:$PUREELK_VERSION
  elif [ "$RUNNING" == "false" ];
  then
      docker start $PUREELK
  else
      print_warn "$PUREELK is already running."
  fi
  
  print_info "Start Logrotate container..."
  RUNNING="$(docker inspect -f '{{.State.Running}}' $LOGROTATE)"
  if [ $? -eq 1 ];
  then
      print_warn "$LOGROTATE doesn't exist, starting..."
      docker run -d -v /var/lib/docker/containers:/var/lib/docker/containers -v $PUREELK_LOG:/var/log/pureelk --name $LOGROTATE \
        -e "LOGS_DIRECTORIES=/var/lib/docker/containers /var/log/pureelk" \
        -e "LOGROTATE_SIZE=20M" \
        -e "LOGROTATE_COPIES=10" \
        -e "LOGROTATE_CRONSCHEDULE=* * * * * *" \
        -e "LOGROTATE_LOGFILE=/logs/logrotatecron.log" \
        blacklabelops/logrotate
  elif [ "$RUNNING" == "false" ];
  then
      docker start $LOGROTATE
  else
      print_warn "$LOGROTATE is already running."
  fi

  print_info "PureELK management endpoint is at http://localhost:80"
  print_info "PureELK Kibana endpoint is at http://localhost:5601"
}

stop_containers() {
  print_info "Stopping PureELK container..."
  docker stop -t 2 $PUREELK

  print_info "Stopping PureELK Kibana container..."
  docker stop $PUREELK_KI

  print_info "Stopping PureELK elasticsearch container..."
  docker stop $PUREELK_ES

  print_info "Stopping Logrotate elasticsearch container..."
  docker stop $LOGROTATE
}

attach_pureelk() {
  print_info "Attaching to PureELK container..."
  docker exec -it $PUREELK bash
}

delete_containers() {
  print_info "Removing PureELK container..."
  docker rm -f $PUREELK

  print_info "Removing PureELK Kibana container..."
  docker rm -f $PUREELK_KI

  print_info "Removing PureElk elastic search container..."
  docker rm -f $PUREELK_ES

  print_info "Removing Logrotate elastic search container..."
  docker rm -f $LOGROTATE
}

if [ -n "$1" ];
  then
    case $1 in
      help)
         print_help
         ;;
      install)
         install
         start_containers $2
         ;;
      start)
         start_containers
         ;;
      stop)
         stop_containers
         ;;
      attach)
         attach_pureelk
         ;;
      delete)
         delete_containers
         ;;
      *)
        print_help
        exit 1
    esac

    else
    print_help
fi
