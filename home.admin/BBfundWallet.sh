#!/bin/bash
clear

# load raspiblitz config data (with backup from old config)
source /home/admin/raspiblitz.info
source /mnt/hdd/app-data/raspiblitz.conf
if [ ${#network} -eq 0 ]; then network=$(cat .network); fi
if [ ${#network} -eq 0 ]; then network="bitcoin"; fi
if [ ${#chain} -eq 0 ]; then
  echo "gathering chain info ... please wait"
  chain=$(${network}-cli getblockchaininfo | jq -r '.chain')
fi

source <(/home/admin/config.scripts/network.aliases.sh getvars $1 $2)

# PRECHECK) check if chain is in sync
if [ $LNTYPE = cl ];then
  BLOCKHEIGHT=$($bitcoincli_alias getblockchaininfo|grep blocks|awk '{print $2}'|cut -d, -f1)
  CLHEIGHT=$($lightningcli_alias getinfo | jq .blockheight)
  if [ $BLOCKHEIGHT -eq $CLHEIGHT ];then
    chainOutSync=0
  else
    chainOutSync=1
  fi
elif [ $LNTYPE = lnd ];then
  chainOutSync=$($lncli_alias getinfo | grep '"synced_to_chain": false' -c)
fi
if [ ${chainOutSync} -eq 1 ]; then
  if [ $LNTYPE = cl ];then
    echo "# FAIL PRECHECK - '$lightningcli_alias getinfo' blockheight is different from 'bitcoind getblockchaininfo' - wait until chain is sync "
  else
    echo "# FAIL PRECHECK - '$lncli_alias getinfo' shows 'synced_to_chain': false - wait until chain is sync "
  fi
  echo 
  echo "# PRESS ENTER to return to menu"
  read key
  exit 0
else
  echo "# OK - the chain is synced"
fi

# execute command
if [ $LNTYPE = cl ];then
  command="$lightningcli_alias newaddr bech32"
elif [ $LNTYPE = lnd ];then
  command="$lncli_alias newaddress p2wkh"
fi
echo "# Calling:"
echo "${command}"
echo
result=$($command)
echo "$result"

# on no result
if [ ${#result} -eq 0 ]; then
  echo "# Empty result - sorry something went wrong - that is unusual."
  echo
  echo "# Press ENTER to return to menu"
  read key
  exit 1
fi

# parse address from result
if [ $LNTYPE = cl ];then
  address=$( echo "$result" | grep "bech32" | cut -d '"' -f4)
elif [ $LNTYPE = lnd ];then
  address=$( echo "$result" | grep "address" | cut -d '"' -f4)
fi

# prepare coin info
coininfo="Bitcoin"
if [ "$chain" = "test" ]; then
  coininfo="TESTNET Bitcoin"
fi

msg="Send ${coininfo} to address --> ${address}\n\nScan the QR code on the LCD with your mobile wallet or copy paste the address.\nThe wallet you sending from needs to support bech32 addresses.\nThis screen will not update - press DONE when send."
if [ "$chain" = "test" ]; then
  msg="${msg} \n\n Get some testnet coins from https://testnet-faucet.mempool.co"
fi

echo "generating QR code ... please wait"
sudo /home/admin/config.scripts/blitz.display.sh qr "$network:${address}"

# raise high focus on onchain wallet balance & pending for the next 15min
/home/admin/_cache.sh focus ln_${LNTYPE}_${chain}net_wallet_onchain_pending 0 900
/home/admin/_cache.sh focus ln_${LNTYPE}_${chain}net_wallet_onchain_balance 0 900

# dialog with instructions while QR code is shown on LCD
whiptail --backtitle "Fund your onchain wallet" \
	 --title "Send ${coininfo}" \
	 --yes-button "DONE" \
	 --no-button "Console QRcode" \
	 --yesno "${msg}" 0 0

# display QR code
if [ $? -eq 1 ]; then
  /home/admin/config.scripts/blitz.display.sh qr-console "$network:${address}"
fi

# clean up
sudo /home/admin/config.scripts/blitz.display.sh hide

# follow up info
if [ $LNTYPE = cl ];then
  string="Wait for confirmations."
elif [ $LNTYPE = lnd ];then
  string="Wait for confirmations. \n\nYou can use info on LCD to check if funds have arrived. \n\nIf you want your lightning node to open channels automatically, activate the 'Autopilot' under 'Activate/Deactivate Services'"
fi
whiptail --backtitle "Fund your onchain wallet" \
       --title "What's next?" \
       --msgbox "$string" 0 0 