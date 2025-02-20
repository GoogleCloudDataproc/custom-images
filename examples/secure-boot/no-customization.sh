#!/bin/bash

function exit_handler() {
  set +ex
  echo "Exit handler invoked"

  # Process disk usage logs from installation period
  rm -f /run/keep-running-df
  sync
  sleep 5.01s
  # compute maximum size of disk during installation
  # Log file contains logs like the following (minus the preceeding #):
#Filesystem     1K-blocks    Used Available Use% Mounted on
#/dev/vda2        7096908 2611344   4182932  39% /
  df / | tee -a "/run/disk-usage.log"

  perl -e '($first, @samples) = grep { m:^/: } <STDIN>;
           unshift(@samples,$first); $final=$samples[-1];
           ($starting)=(split(/\s+/,$first))[2] =~ /^(\d+)/;
             ($ending)=(split(/\s+/,$final))[2] =~ /^(\d+)/;
           @siz=( sort { $a => $b }
                   map { (split)[2] =~ /^(\d+)/ } @samples );
$max=$siz[0]; $min=$siz[-1]; $inc=$max-$starting;
print( "     samples-taken: ", scalar @siz, $/,
       "starting-disk-used: $starting", $/,
       "  ending-disk-used: $ending", $/,
       " maximum-disk-used: $max", $/,
       " minimum-disk-used: $min", $/,
       "      increased-by: $inc", $/ )' < "/run/disk-usage.log"

  echo "exit_handler has completed"

  # zero free disk space
  dd if=/dev/zero of=/zero
  sync
  sleep 3s
  rm -f /zero

  return 0
}

# Monitor disk usage in a screen session
df / > "/run/disk-usage.log"
touch "/run/keep-running-df"
screen -d -m -LUS keep-running-df \
  bash -c "while [[ -f /run/keep-running-df ]] ; do df / | tee -a /run/disk-usage.log ; sleep 5s ; done"

trap exit_handler EXIT
