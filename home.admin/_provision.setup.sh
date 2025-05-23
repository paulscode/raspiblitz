#!/bin/bash

# check if started with sudo
if [ "$EUID" -ne 0 ]; then
  echo "error='run as root'"
  exit 1
fi

# this provision file is just executed on fresh setups
# not on recoveries or updates

# LOGFILE - store debug logs of bootstrap
logFile="/home/admin/raspiblitz.log"

# INFOFILE - state data from bootstrap
infoFile="/home/admin/raspiblitz.info"
source ${infoFile}

# SETUPFILE - setup data of RaspiBlitz
setupFile="/var/cache/raspiblitz/temp/raspiblitz.setup"
source ${setupFile}

# CONFIGFILE - configuration of RaspiBlitz
configFile="/mnt/hdd/app-data/raspiblitz.conf"
source ${configFile}

# log header
echo "###################################" >> ${logFile}
echo "# _provision.setup.sh" >> ${logFile}
echo "###################################" >> ${logFile}

# make sure a raspiblitz.conf exists
confExists=$(ls /mnt/hdd/app-data/raspiblitz.conf 2>/dev/null | grep -c "raspiblitz.conf")
if [ "${confExists}" != "1" ]; then
    /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "missing-config" "No raspiblitz.conf abvailable." ${logFile}
    exit 6
fi

# make sure raspiblitz.conf has an blitzapi entry when setup thru fatpack image (blitzapi=on in raspiblitz.info)
if [ "${blitzapi}" == "on" ]; then
  /home/admin/config.scripts/blitz.conf.sh set blitzapi on >> ${logFile}
fi

###################################
# Preserve SSH keys
# just copy dont link anymore
# see: https://github.com/rootzoll/raspiblitz/issues/1798
/home/admin/_cache.sh set message "SSH Keys"

# link ssh directory from SD card to HDD
/home/admin/config.scripts/blitz.ssh.sh backup

###################################
# Prepare Blockchain Service
/home/admin/_cache.sh set message "Blockchain Setup"
source <(/home/admin/_cache.sh get network chain hddBlocksBitcoin)

if [ "${network}" == "" ]; then
  /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "missing-network" "" "" ${logFile}
  exit 2
fi

if [ "${chain}" == "" ]; then
  /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "missing-chain" "" "" ${logFile}
  exit 3
fi

# copy configs files and directories
echo ""
echo "*** Prepare ${network} ***" >> ${logFile}
mkdir /mnt/hdd/app-storage/${network} >>${logFile} 2>&1
chown -R bitcoin:bitcoin /mnt/hdd/app-storage/${network} >>${logFile} 2>&1
sudo -u bitcoin mkdir /mnt/hdd/app-storage/${network}/blocks >>${logFile} 2>&1
sudo -u bitcoin mkdir /mnt/hdd/app-storage/${network}/chainstate >>${logFile} 2>&1
cp /home/admin/assets/${network}.conf /mnt/hdd/app-data/${network}/${network}.conf
chown bitcoin:bitcoin /mnt/hdd/app-data/${network}/${network}.conf >>${logFile} 2>&1
mkdir /home/admin/.${network} >>${logFile} 2>&1
cp /home/admin/assets/${network}.conf /home/admin/.${network}/${network}.conf
chown -R admin:admin /home/admin/.${network} >>${logFile} 2>&1

# make sure all directories are linked
/home/admin/config.scripts/blitz.data.sh link >> ${logFile}

# test bitcoin config
confExists=$(ls /mnt/hdd/app-data/${network}/${network}.conf | grep -c "${network}.conf")
echo "File Exists: /mnt/hdd/app-data/${network}/${network}.conf --> ${confExists}" >> ${logFile}

# set password B as RPC password (from setup file)
echo "# setting PASSWORD B" >> ${logFile}
/home/admin/config.scripts/blitz.passwords.sh set b "${passwordB}" >> ${logFile}

# optimize RAM for blockchain validation (bitcoin only)
if [ "${network}" == "bitcoin" ]; then
  echo "*** Optimizing RAM for Sync ***" >> ${logFile}
  kbSizeRAM=$(cat /proc/meminfo | grep "MemTotal" | sed 's/[^0-9]*//g')
  echo "kbSizeRAM(${kbSizeRAM})" >> ${logFile}
  echo "dont forget to reduce dbcache once IBD is done" > "/mnt/hdd/app-storage/${network}/blocks/selfsync.flag"
  # RP4 8GB
  if [ ${kbSizeRAM} -gt 7500000 ]; then
    echo "Detected RAM >=8GB --> optimizing ${network}.conf" >> ${logFile}
    sed -i "s/^dbcache=.*/dbcache=4096/g" /mnt/hdd/app-data/${network}/${network}.conf
  # RP4 4GB
  elif [ ${kbSizeRAM} -gt 3500000 ]; then
    echo "Detected RAM >=4GB --> optimizing ${network}.conf" >> ${logFile}
    sed -i "s/^dbcache=.*/dbcache=2560/g" /mnt/hdd/app-data/${network}/${network}.conf
  # RP4 2GB
  elif [ ${kbSizeRAM} -gt 1500000 ]; then
    echo "Detected RAM >=2GB --> optimizing ${network}.conf" >> ${logFile}
    sed -i "s/^dbcache=.*/dbcache=1536/g" /mnt/hdd/app-data/${network}/${network}.conf
  #RP3/4 1GB
  else
    echo "Detected RAM <=1GB --> optimizing ${network}.conf" >> ${logFile}
    sed -i "s/^dbcache=.*/dbcache=512/g" /mnt/hdd/app-data/${network}/${network}.conf
  fi
fi

# start network service
echo ""
echo "*** Start ${network} (SETUP) ***" >> ${logFile}
/home/admin/_cache.sh set message "Blockchain Testrun"
echo "- This can take a while .." >> ${logFile}
systemctl daemon-reload >> ${logFile}
systemctl enable ${network}d.service
systemctl start ${network}d.service

# check if bitcoin has started
bitcoinRunning=0
loopcount=0
while [ ${bitcoinRunning} -eq 0 ]
do
  >&2 echo "# (${loopcount}/50) checking if ${network}d is running ... " >> ${logFile}
  bitcoinRunning=$(sudo -u bitcoin ${network}-cli getblockchaininfo 2>/dev/null | grep "initialblockdownload" -c)
  sleep 8
  sync
  loopcount=$(($loopcount +1))
  if [ ${loopcount} -gt 50 ]; then
    /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "btc-testrun-fail" "${network}d not running" "sudo -u bitcoin ${network}-cli getblockchaininfo | grep "initialblockdownload" -c --> ${bitcoinRunning}" ${logFile}
    exit 4
  fi
done
echo "OK ${network} startup successful " >> ${logFile}

###################################
# Prepare Lightning
source /mnt/hdd/app-data/raspiblitz.conf
echo "Prepare Lightning (${lightning})" >> ${logFile}

if [ "${hostname}" == "" ]; then
  /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "missing-hostname" "" "" ${logFile}
  exit 41
fi

if [ "${lightning}" != "lnd" ]; then

  ###################################
  # Remove LND from systemd
  echo "Remove LND" >> ${logFile}
  /home/admin/_cache.sh set message "Deactivate Lightning"
  systemctl disable lnd 2>/dev/null
  rm /etc/systemd/system/lnd.service 2>/dev/null
  systemctl daemon-reload
fi

if [ "${lightning}" == "lnd" ]; then

  ###################################
  # LND
  echo "############## Setup LND" >> ${logFile}
  /home/admin/_cache.sh set message "LND Setup"

  # password C (raspiblitz.setup)
  if [ "${passwordC}" == "" ] && [ "${lndrescue}" = "" ]; then
    /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "missing-passwordc" "config: missing passwordC" "" ${logFile}
    exit 5
  fi

  # install lnd if needed (sd card without fatpack)
  # if already installed - it will just skip
  /home/admin/config.scripts/lnd.install.sh install >> ${logFile}

  # if user uploaded an LND rescue file (raspiblitz.setup)
  if [ "${lndrescue}" != "" ]; then
    echo "Restore LND data from uploaded rescue file ${lndrescue} ..." >> ${logFile}
    source <(/home/admin/config.scripts/lnd.backup.sh lnd-import "${lndrescue}")
    if [ "${error}" != "" ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lndrescue-import" "setup: lnd import backup failed" "${error}" ${logFile}
      exit 6
    fi
    # fix config after import
    /home/admin/config.scripts/lnd.install.sh on mainnet
  else
    # preparing new LND config (raspiblitz.setup)
    echo "Creating new LND config ..." >> ${logFile}
    /home/admin/config.scripts/lnd.install.sh on mainnet
    /home/admin/config.scripts/lnd.setname.sh mainnet ${hostname}
  fi

  # make sure all directories are linked
  /home/admin/config.scripts/blitz.data.sh link

  # check if now a config exists
  configLinkedCorrectly=$(ls /mnt/hdd/app-data/lnd/lnd.conf | grep -c "lnd.conf")
  if [ "${configLinkedCorrectly}" != "1" ]; then
    /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lnd-link-broken" "link /mnt/hdd/app-data/lnd/lnd.conf broken" "" ${logFile}
    exit 7
  fi

  # Init LND service & start
  echo "*** Init LND Service & Start ***" >> ${logFile}
  /home/admin/_cache.sh set message "LND Testrun"

  # just in case
  systemctl stop lnd 2>/dev/null
  systemctl disable lnd 2>/dev/null

  # copy lnd service
  cp /home/admin/assets/lnd.service /etc/systemd/system/lnd.service >> ${logFile}

  # start lnd up
  echo "Starting LND Service ..." >> ${logFile}
  systemctl enable lnd >> ${logFile}
  systemctl start lnd >> ${logFile}
  echo "Starting LND Service ... executed" >> ${logFile}

  # check that lnd started
  lndRunning=0
  loopcount=0
  while [ ${lndRunning} -eq 0 ]
  do
    lndRunning=$(systemctl status lnd.service | grep -c running)
    if [ ${lndRunning} -eq 0 ]; then
      date +%s >> ${logFile}
      echo "LND not ready yet ... waiting another 60 seconds (${loopcount})." >> ${logFile}
      sleep 10
    fi
    loopcount=$(($loopcount +1))
    if [ ${loopcount} -gt 100 ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lnd-start-fail" "lnd service not getting to running status" "sudo systemctl status lnd.service | grep -c running --> ${lndRunning}" ${logFile}
      exit 8
    fi
  done
  echo "OK - LND is running" ${logFile}
  sleep 10

  # Check LND health/fails (to be extended)
  tlsExists=$(ls /mnt/hdd/app-data/lnd/tls.cert 2>/dev/null | grep -c "tls.cert")
  if [ ${tlsExists} -eq 0 ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lnd-no-tls" "lnd not created TLS cert" "no /mnt/hdd/app-data/lnd/tls.cert" ${logFile}
      exit 9
  fi


  # WALLET --> LNDRESCUE
  if  [ "${lndrescue}" != "" ];then

    echo "WALLET --> LNDRESCUE " >> ${logFile}
    /home/admin/_cache.sh set message "LND Wallet (LNDRESCUE)"

  # WALLET --> SEED (+ SCB to be restored later)
  elif [ "${seedWords}" != "" ]; then

    echo "WALLET --> SEED" >> ${logFile}
    /home/admin/_cache.sh set message "LND Wallet (SEED)"
    source <(/home/admin/config.scripts/lnd.initwallet.py seed mainnet "${passwordC}" "${seedWords}" "${seedPassword}")
    if [ "${err}" != "" ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lnd-wallet-seed" "lnd.initwallet.py seed returned error" "/home/admin/config.scripts/lnd.initwallet.py seed mainnet ... --> ${err} + ${errMore}" ${logFile}
      exit 12
    fi

    # set lnd into recovery mode (gets activated after setup reboot)
    /home/admin/config.scripts/lnd.backup.sh mainnet recoverymode on >> ${logFile}
    echo "Rescanning will activate after setup-reboot ..." >> ${logFile}


  # WALLET --> NEW
  else

    echo "# WALLET --> NEW" >> ${logFile}
    /home/admin/_cache.sh set message "LND Wallet (NEW)"
    source <(/home/admin/config.scripts/lnd.initwallet.py new mainnet "${passwordC}")
    if [ "${err}" != "" ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lnd-wallet-new" "lnd.initwallet.py new returned error" "/home/admin/config.scripts/lnd.initwallet.py new mainnet ... --> ${err} + ${errMore}" ${logFile}
      /home/admin/_cache.sh set state "error"
      /home/admin/_cache.sh set message "setup: lnd wallet NEW failed"
      echo "FAIL see ${logFile}"
      echo "FAIL: setup: lnd wallet SEED failed (2)" >> ${logFile}
      echo "${err}" >> ${logFile}
      echo "${errMore}" >> ${logFile}
      exit 13
    fi

    # write created seedwords into SETUPFILE to be displayed to user on final setup later
    echo "# writing seed info to setup file" >> ${logFile}
    echo "seedwordsNEW='${seedwords}'" >> ${setupFile}
    echo "seedwords6x4NEW='${seedwords6x4}'" >> ${setupFile}

  fi

  # sync macaroons & TLS to other users
  echo "*** Copy LND Macaroons to user admin ***" >> ${logFile}
  /home/admin/_cache.sh set message "LND Credentials"

  # check if macaroon exists now - if not fail
  attempt=0
  while [ $(sudo -u bitcoin ls -la /mnt/hdd/app-data/lnd/data/chain/${network}/${chain}net/admin.macaroon 2>/dev/null | grep -c admin.macaroon) -eq 0 ]; do
    echo "Waiting 2 mins for LND to create macaroons ... (${attempt}0s)" >> ${logFile}
    sleep 10
    attempt=$((attempt+1))
    if [ $attempt -eq 12 ];then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lnd-no-macaroons" "lnd did not create macaroons" "/mnt/hdd/app-data/lnd/data/chain/${network}/${chain}net/admin.macaroon --> missing" ${logFile}
      exit 14
    fi
  done

  # now sync macaroons & TLS to other users
  /home/admin/config.scripts/lnd.credentials.sh sync "${chain:-main}net" >> ${logFile}

  # make a final lnd check
  source <(/home/admin/config.scripts/lnd.check.sh basic-setup)
  if [ "${err}" != "" ]; then
    /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "lnd-check-error" "lnd.check.sh basic-setup with error" "/home/admin/config.scripts/lnd.check.sh basic-setup --> ${err}" ${logFile}
    exit 15
  fi

  # stop lnd for the rest of the provision process
  echo "stopping lnd for the rest provision again (will start on next boot)" >> ${logFile}
  systemctl stop lnd >> ${logFile}

fi

if [ "${lightning}" == "cl" ]; then

  ###################################
  # c-lightning
  echo "############## c-lightning" >> ${logFile}

  # install c-lightning (when not done by sd card fatpack)
  # if already installed - will skip
  /home/admin/_cache.sh set message "Core Lightning Install"
  /home/admin/config.scripts/cl.install.sh install >> ${logFile}

  echo "# switch mainnet config on" >> ${logFile}
  /home/admin/_cache.sh set message "Core Lightning Setup"
  /home/admin/config.scripts/cl.install.sh on mainnet >> ${logFile}

  # OLD WALLET FROM CLIGHTNING RESCUE
  if [ "${clrescue}" != "" ]; then

    echo "Restore CL data from uploaded rescue file ${clrescue} ..." >> ${logFile}
    source <(/home/admin/config.scripts/cl.backup.sh cl-import "${clrescue}")
    if [ "${error}" != "" ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "cl-import-backup" "cl.backup.sh cl-import with error" "/home/admin/config.scripts/cl.backup.sh cl-import ${clrescue} --> ${error}" ${logFile}
      exit 16
    fi

    # detect if the imported hsm_secret is encrypted and set in raspiblitz.conf
    # use the variables for the default network
    source <(/home/admin/config.scripts/network.aliases.sh getvars cl mainnet)
    hsmSecretPath="/home/bitcoin/.lightning/bitcoin/hsm_secret"
    # check if encrypted
    trap 'rm -f "$output"' EXIT
    output=$(mktemp -p /dev/shm/)
    echo "test" | sudo -u bitcoin lightning-hsmtool decrypt "$hsmSecretPath" \
     2> "$output"
    if [ "$(grep -c "hsm_secret is not encrypted" < "$output")" -gt 0 ];then
      echo "# The hsm_secret is not encrypted"
      echo "# Record in raspiblitz.conf"
      /home/admin/config.scripts/blitz.conf.sh set "${netprefix}clEncryptedHSM" "off"
    else
      cat $output
      echo "# The hsm_secret is encrypted"
      echo "# Record in raspiblitz.conf"
      /home/admin/config.scripts/blitz.conf.sh set "${netprefix}clEncryptedHSM" "off"
    fi

    # update from raspiblitz.conf
    source ${configFile}
    # set the lightningd service file on each active network
    # init backup plugin, restart cl
    if [ "${cl}" == "on" ] || [ "${cl}" == "1" ]; then
      /home/admin/config.scripts/cl.install-service.sh mainnet
      /home/admin/config.scripts/cl-plugin.backup.sh on mainnet
    fi
    if [ "${tcl}" == "on" ] || [ "${tcl}" == "1" ]; then
      /home/admin/config.scripts/cl.install-service.sh testnet
      /home/admin/config.scripts/cl-plugin.backup.sh on testnet
    fi
    if [ "${scl}" == "on" ] || [ "${scl}" == "1" ]; then
      /home/admin/config.scripts/cl.install-service.sh signet
      /home/admin/config.scripts/cl-plugin.backup.sh on signet
    fi

  # OLD WALLET FROM SEEDWORDS
  elif [ "${seedWords}" != "" ]; then

    echo "# Restore CL wallet from seedWords ..." >> ${logFile}
    source <(/home/admin/config.scripts/cl.hsmtool.sh seed-force mainnet "${seedWords}" "${seedPassword}")

    # check if wallet really got created
    walletExistsNow=$(ls /home/bitcoin/.lightning/bitcoin/hsm_secret 2>/dev/null | grep -c "hsm_secret")
    if [ $walletExistsNow -eq 0 ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "cl-wallet-seed" "cl.hsmtool.sh seed-force not created wallet" "ls /home/bitcoin/.lightning/bitcoin/hsm_secret --> 0" ${logFile}
      exit 17
    fi

  # NEW WALLET
  else

    echo "# Generate new CL wallet ..." >> ${logFile}

    # a new wallet is generated in /home/admin/config.scripts/cl.install.sh on mainnet
    walletExistsNow=$(ls /home/bitcoin/.lightning/bitcoin/hsm_secret 2>/dev/null | grep -c "hsm_secret")
    seedwordsFileExitNow=$(ls /home/bitcoin/.lightning/bitcoin/seedwords.info 2>/dev/null | grep -c "seedwords.info")
    if [ "${walletExistsNow}" -gt 0 ] && [ "${seedwordsFileExitNow}" -gt 0 ]; then
      # get existing ${seedwords} and "${seedwords6x4}"
      source /home/bitcoin/.lightning/bitcoin/seedwords.info
    else
      # generate new wallet
      source <(/home/admin/config.scripts/cl.hsmtool.sh new-force mainnet)
    fi

    # check if got new seedwords
    if [ "${seedwords}" == "" ] || [ "${seedwords6x4}" == "" ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "cl-wallet-new-noseeds" "cl.hsmtool.sh new-force did not returned seedwords" "/home/admin/config.scripts/cl.hsmtool.sh new-force mainnet --> seedwords=''" ${logFile}
      exit 18
    fi

    # check if wallet really got created
    walletExistsNow=$(ls /home/bitcoin/.lightning/bitcoin/hsm_secret 2>/dev/null | grep -c "hsm_secret")
    if [ $walletExistsNow -eq 0 ]; then
      /home/admin/config.scripts/blitz.error.sh _provision.setup.sh "cl-wallet-new-nowallet" "cl.hsmtool.sh new-force did not create wallet" "/home/bitcoin/.lightning/bitcoin/hsm_secret --> missing" ${logFile}
      exit 19
    fi

    # write created seedwords into SETUPFILE to be displayed to user on final setup later
    echo "# writing seed info to setup file" >> ${logFile}
    echo "seedwordsNEW='${seedwords}'" >> ${setupFile}
    echo "seedwords6x4NEW='${seedwords6x4}'" >> ${setupFile}

  fi

  # stop c-lightning for the rest of the provision process
  echo "stopping lightningd for the rest provision again (will start on next boot)" >> ${logFile}
  systemctl stop lightningd >> ${logFile}

fi

# stop bitcoind for the rest of the provision process
echo "stopping bitcoind for the rest provision again (will start on next boot)" >> ${logFile}
systemctl stop bitcoind >> ${logFile}

/home/admin/_cache.sh set message "Provision Setup Finish"
echo "END Setup"  >> ${logFile}
exit 0