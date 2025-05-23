#!/bin/bash

# command info
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "-help" ]; then
 echo "# handle the internet connection"
 echo "# internet.sh status [local|online|global]"
 echo "# internet.sh ipv6 [on|off]"
 echo "# internet.sh update-publicip [?domain]"
 exit 1
fi

# check when to global check
runGlobal=0
runOnline=0
if [ "$2" == "online" ]; then
  runOnline=1
fi
if [ "$2" == "global" ]; then
  runOnline=0
  runGlobal=1
fi
if [ "$1" == "update-publicip" ]; then
  runGlobal=1
fi

# load local config (but should also work if not available)
source /mnt/hdd/app-data/raspiblitz.conf 2>/dev/null

#############################################
# FUNCTIONS
isValidIP() {
  if [ "$1" != "${1#*[0-9].[0-9]}" ]; then
    # IPv4
    echo 1
  elif [ "$1" != "${1#*:[0-9a-fA-F]}" ]; then
    # IPv6
    echo 1
  else
    # unknown
    echo 0
  fi
}

#############################################
# by default ipv6 is off (for publicIP)
if [ "${ipv6}" = "" ]; then
  ipv6="off"
fi

#############################################
# get active network device (eth0 or wlan0) & traffic
networkDevice=$(ip addr | grep -v "lo:" | grep 'state UP' | tr -d " " | cut -d ":" -f2 | head -n 1)
# get network traffic
# ifconfig does not show eth0 on Armbian or in a VM - get first traffic info
isArmbian=$(cat /etc/os-release 2>/dev/null | grep -c 'Debian')
if [ ${isArmbian} -gt 0 ] || [ ! -d "/sys/class/thermal/thermal_zone0/" ]; then
  network_rx=$(ifconfig 2>/dev/null | grep -m1 'RX packets' | awk '{ print $6$7 }' | sed 's/[()]//g')
  network_tx=$(ifconfig 2>/dev/null | grep -m1 'TX packets' | awk '{ print $6$7 }' | sed 's/[()]//g')
else
  network_rx=$(ifconfig ${networkDevice} 2>/dev/null | grep 'RX packets' | awk '{ print $6$7 }' | sed 's/[()]//g')
  network_tx=$(ifconfig ${networkDevice} 2>/dev/null | grep 'TX packets' | awk '{ print $6$7 }' | sed 's/[()]//g')
fi

#############################################
# get local IP (from different sources)
localip_ALL=$(hostname -I | awk '{print $1}')
if [ $(isValidIP ${localip_ALL}) -eq 0 ]; then
  localip_ALL=""
fi
localip_LAN=$(ip addr 2>/dev/null | grep 'state UP' -A2 | grep -E -v 'docker0|veth' | grep -E -i '([eth][0-9]$)*' | tail -n1 | awk '{print $2}' | cut -f1 -d'/')
if [ $(isValidIP ${localip_LAN}) -eq 0 ]; then
  localip_LAN=""
fi
localip="${localip_ALL}"
if [ ${#localip_LAN} -gt 0 ]; then
  # prefer local IP over LAN over all other if available
  localip="${localip_LAN}"
fi

#############################################
# get local IP Range
localiprange=$(ip -o -4 addr show ${networkDevice} | awk '/scope global/ {split($4,ip,"/"); split(ip[1],octets,"."); printf "%s.%s.%s.0/%s\n", octets[1], octets[2], octets[3], ip[2]}')

#############################################
# check DHCP
dhcp=1
if [ "${localip:0:4}" = "169." ]; then
 dhcp=0
fi

#############################################
# check for Wifi
configWifiExists=0
if [ "$EUID" -eq 0 ]; then
  configWifiExists=$(cat /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null| grep -c "network=")
else
  configWifiExists=$(sudo cat /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null| grep -c "network=")
fi


#############################################
## check for internet connection
online=0
if [ "${peers}" != "0" ] && [ "${peers}" != "" ]; then
  # bitcoind has peers - so device is online
  online=1
fi

if [ ${runOnline} -eq 1 ]; then

  if [ "$EUID" -eq 0 ]; then
    # first quick check if bitcoind has peers - if so the client is online
    # if not then recheck by pinging different sources if online
    btc_online="0"
    source <(timeout 2 /home/admin/config.scripts/bitcoin.monitor.sh mainnet status)
    if [ "${btc_online}" == "1" ]; then
      # bitcoind has peers - so device is online
      online=1
    fi
  fi

  # next try if tor test site can be called
  if [ ${online} -eq 0 ]; then
    torFunctional="0"
    source <(timeout 5 /home/admin/config.scripts/tor.network.sh status)
    if [ "${torFunctional}" == "1" ]; then
      # tor delivers content
      online=1
    fi
  fi
  if [ ${online} -eq 0 ] && [ "${dnsServer}" != "" ]; then
    # test with netcat to avoid firewall issues with ICMP packets
    online=$(nc -v -z -w 3 ${dnsServer} 53 &> /dev/null && echo "1" || echo "0")
  fi
  if [ ${online} -eq 0 ]; then
    # test with netcat to avoid firewall issues with ICMP packets
    online=$(nc -v -z -w 3 8.8.8.8 53 &> /dev/null && echo "1" || echo "0")
  fi
  if [ ${online} -eq 0 ]; then
    # re-test with other server
    online=$(ping 1.0.0.1 -c 1 -W 2 2>/dev/null | grep -c '1 received')
  fi
  if [ ${online} -eq 0 ]; then
    # re-test with other server
    online=$(ping 8.8.8.8 -c 1 -W 2 2>/dev/null | grep -c '1 received')
  fi
  if [ ${online} -eq 0 ]; then
    # re-test with other server (IPv6)
    online=$(ping 2620:119:35::35 -c 1 -W 2 2>/dev/null | grep -c '1 received')
  fi
  if [ ${online} -eq 0 ]; then
    # re-test with other server
    online=$(ping 208.67.222.222 -c 1 -W 2 2>/dev/null | grep -c '1 received')
  fi
  if [ ${online} -eq 0 ]; then
    # re-test with other server (IPv6)
    online=$(ping 2001:4860:4860::8844 -c 1 -W 2 2>/dev/null | grep -c '1 received')
  fi
  if [ ${online} -eq 0 ]; then
    # re-test with other server
    online=$(ping 1.1.1.1 -c 1 -W 2 2>/dev/null | grep -c '1 received')
  fi
fi


#############################################
# check for internet connection
if [ ${runGlobal} -eq 1 ]; then

  ###########################################
  # Static IP
  # the static IP to override globalIP and publicIP detection
  if [ "${staticIP}" != "" ]; then
    echo "## static IP found: ${staticIP}"
  fi

  ###########################################
  # Global IP
  # the public IP that can be detected from outside
  if [ "${staticIP}" == "" ]; then
    globalIP=""
    echo "# getting public IP from third party service"
    if [ "${ipv6}" == "on" ]; then
      globalIP=$(curl -s -f -S -m 10 http://v6.ipv6-test.com/api/myip.php 2>/dev/null)
    else
      globalIP=$(curl -s -f -S -m 10 http://v4.ipv6-test.com/api/myip.php 2>/dev/null)
    fi
    echo "##  curl returned:  ${globalIP}"
    echo "##  curl exit code: ${?}"
  else
    globalIP=${staticIP}
    echo "##  staticIP as globalIP: ${staticIP}"
  fi

  # sanity check on IP data
  # see https://github.com/rootzoll/raspiblitz/issues/371#issuecomment-472416349
  echo "# sanity check of IP data:"
  if [[ $globalIP =~ ^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$ ]]; then
    echo "# OK IPv6 for ${globalIP}"
  elif [[ $globalIP =~ ^([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then
    echo "# OK IPv4 for ${globalIP}"
  else
    echo "# FAIL - not an IPv4 or IPv6 address"
    globalIP=""
  fi

  # prevent having no publicIP set at all and LND getting stuck
  # https://github.com/rootzoll/raspiblitz/issues/312#issuecomment-462675101
  if [ ${#globalIP} -eq 0 ]; then
    if [ "${ipv6}" == "on" ]; then
      globalIP="::1"
    else
      if [ "${staticIP}" == "" ]; then
        # only if publicIP is empty, dont prefer 127.0.0.1
        if [ "${publicIP}" != "" ]; then
          globalIP="${publicIP}"
        else
          globalIP="127.0.0.1"
        fi
      else
        globalIP="${staticIP}"
      fi
    fi
  fi

  ##########################################
  # Public IP
  # the public that is maybe set by raspiblitz config file (overriding auto-detection)
  if [ "${publicIP}" == "" ]; then
    if [ "${staticIP}" == "" ]; then
      # if publicIP is not set by config ... use detected global IP
      if [ "${ipv6}" == "on" ]; then
        # use ipv6 with square brackets so that it can be used in http addresses like a IPv4
        publicIP="[${globalIP}]"
      else
        publicIP="${globalIP}"
      fi
    else
      # if a static IP was set, use it as public IP
      publicIP="${staticIP}"
    fi
  fi

  ##########################################
  # Clean IP
  # really just the IP value - without the default brackets if IPv6
  # for IPV4 case the "tr" will do no harm.
  cleanIP=$(echo "${publicIP}" | tr -d '[]')

fi

#############################################
if [ "$1" == "status" ]; then

  echo "### LOCAL INTERNET ###"
  echo "localip=${localip}"
  echo "localiprange=${localiprange}"
  echo "dhcp=${dhcp}"
  echo "configWifiExists=${configWifiExists}"
  echo "network_device=${networkDevice}"
  echo "network_rx='${network_rx}'"
  echo "network_tx='${network_tx}'"
  echo "### GLOBAL INTERNET ###"
  if [ ${runOnline} -eq 1 ]; then
    echo "online=${online}"
  fi
  if [ ${runGlobal} -eq 1 ]; then
    echo "ipv6=${ipv6}"
    echo "# globalip --> ip detected from the outside"
    echo "globalip=${globalIP}"
    echo "# publicip --> may consider the static IP overide by raspiblitz config"
    echo "publicip=${publicIP}"
    echo "# cleanip --> the publicip with no brackets like used on IPv6"
    echo "cleanip=${cleanIP}"
  else
    echo "# for more global internet info use 'status global'"
  fi
  exit 0

#############################################
elif [ "$1" == "update-publicip" ]; then

  if [ "$2" != "" ]; then
    echo "ip_changed=0"
    publicIP="$2"
  elif  [ "${globalIP}" == "${cleanIP}" ]; then
    echo "ip_changed=0"
  else
    echo "ip_changed=1"
    if [ "${ipv6}" == "on" ]; then
      # use ipv6 with square brackets so that it can be used in http addresses like an IPv4
      publicIP="[${globalIP}]"
    else
      publicIP="${globalIP}"
    fi
    echo "publicip=${publicIP}"
  fi

  # store to raspiblitz.conf new publiciP
  /home/admin/config.scripts/blitz.conf.sh set publicIP "${publicIP}"
  exit 0

#############################################
elif [ "$1" == "ipv6" ]; then

  if [ "$2" == "on" ]; then

    echo "# Switching IPv6 ON"

    # set config
    /home/admin/config.scripts/blitz.conf.sh set ipv6 "on"
    exit 0

  elif [ "$2" == "off" ]; then

    echo "# Switching IPv6 OFF"

    # set config
    /home/admin/config.scripts/blitz.conf.sh set ipv6 "off"

    exit 0

  else
    echo "error='unknown second parameter'"
    exit 1
  fi

else
  echo "err='parameter not known - run with -help'"
fi
