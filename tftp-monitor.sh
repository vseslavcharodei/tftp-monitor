#!/bin/sh

# Define variables:
# nlines - number of lines script should check from the end of the file for any detected attempts to connect to TFTP over defined limit
# Modify nlines in conjuction with schedule of the script depending on the frequency of log messages writes to syslog
# log_file - log file that should be checked
# monitor_log_file - file where script should redirect its output
nlines=100
log_file="/host_logs/syslog"
monitor_log_file="/host_logs/mon_logs/tftp_monitor.log"

# Log function
function log {
    msg=$1
    # Check if $monitor_log_file is available for write
	if [ -w "${monitor_log_file}" ]; then
        echo "$(date +"%b %d %T"): ${msg}" | tee -a $monitor_log_file
    else
        echo "$(date +"%b %d %T"): ${msg}"
    fi
}

log "Start script $0"

# Check if $log_file can be read
if [ -r "$log_file" ]; then
    log "Checked file: ${log_file} exists. Proceed with TFTP check."
else
    log "Checked file: ${log_file} is not available for read. Stop execution."
    exit 1 #here cronjob pod will get Error status and will be restarted by controller according to restartPolicy specified in job template
fi

# Check if there was any attempts to access TFTP on host machine over the allowed rate in the last N lines of log:
tftp_stats=$(\
    tail -${nlines} ${log_file}|\
    awk -F "SRC=" '{print $2}'|\
        sed '/^$/d'|\
        awk -F " DST=" '{print $1}'|\
        sort|uniq -c|sort -k 1\
)

# If brute-force attempts have not been detected, just print log message
if [ -z "$tftp_stats" ]; then
    log "Brute-force atteampts have not been detected!"
# Else send monitoring alert
else
    log "Brute-force atteampts have been detected!"
    log "Here is the statistics:"
	log "$tftp_stats"

    ## REMOTE_SMTP_IP, REMOTE_SMTP_PORT, NODE_IP may be different from node to node where the script is deployed, so decided to put this as env variables
    ##  - but the main reason is show that I've also considered how variables can be passed to scripts in Kubernetes

    # Check for remote_smtp availability
	log "Checking if remote SMPT ${REMOTE_SMTP_IP}:${REMOTE_SMTP_PORT} is available."
    nc -zv $REMOTE_SMTP_IP $REMOTE_SMTP_PORT

    # If remote SMTP is available, send email alert
    if [ $? -eq 0 ]; then
        log "Composing and sending email alert."

        # Compose and send email:
        email_to="admin-kubernetes@gmail.com"
        email_from="root@tftp-monitor"
        sbj="TFPT brute-force is detected on $NODE_IP"

        sendmail -S ${REMOTE_SMTP_IP}:${REMOTE_SMTP_PORT} $email_to <<EOF
From:$email_from
Subject:$sbj
Hi,

Someone tried to brute-force TFTP connection on ${NODE_IP}.

Here is the report:
$tftp_stats
EOF

        # If sendmail fails due to some reason, we need to try re-executing our check immidiately
        if [ $? -ne 0 ]; then
            log "Sending email failed due to some reason."
			exit 1
		else
		    log "Email has been sent."
        fi
    # Else skip sending alert
    else
        log "Remote SMTP server ${remote_smtp} is not available. Alert cannot be sent."
		exit 1 #here cronjob pod will get Error status and will be restarted by controller according to restartPolicy specified in job template
		       #error code here is essential, because admin won't now about bruteforce in case remote SMTP is not available. Thus, kubernetes should try to retry script to notify admin.
    fi
fi
