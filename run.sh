#!/bin/bash

# Log file path
log_file="/var/log/exim_mainlog"

# API URL for sending data
api_url="https://shoniz.com/mailforwarder/mailforwarder.php"

# Check last 10000 lines of the log
lines=$(tail -n 10000 "$log_file")

# Current time and 10 minutes ago
current_time=$(date +%s)
one_minute_ago=$((current_time - 6000))

# Store sent email information
declare -A sent_emails

# Process log lines for sent and received emails
echo "Processing log lines..."

echo "$lines" | while read line; do
    # Check email timestamp and convert to epoch
    timestamp=$(echo "$line" | grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' | head -n 1)
    timestamp_epoch=$(date -d "$timestamp" +%s)

    # If the email timestamp is within the last minute
    if [ "$timestamp_epoch" -gt "$one_minute_ago" ]; then
        # Extract the sender and receiver based on the new format
        sender=$(echo "$line" | grep -oP '(?<=<= ).*?(?= H=)')
        receiver=$(echo "$line" | grep -oP '(?<=for ).*?(?=$| )')

        # Check if sender and receiver were found
        if [[ -z "$sender" || -z "$receiver" ]]; then
            # Check for email delivery confirmation without sender/receiver format
            if [[ "$line" =~ "Saved" ]]; then
                # If email has been delivered to the receiver, extract the receiver and subject
                receiver=$(echo "$line" | grep -oP '(?<=for ).*?(?=$| )')
                subject=$(echo "$line" | grep -oP 'T="\K[^"]+')
                echo "Email delivered to $receiver at $timestamp with subject: $subject"

                # Send data to API
                curl -X POST "$api_url" \
                    -d "sender=unknown" \
                    -d "receiver=$receiver" \
                    -d "subject=$subject" \
                    -d "timestamp=$timestamp"
                echo "Email information sent to API: $subject"
            fi
            continue
        fi

        echo "Found sender: $sender, receiver: $receiver"

        # Check for sent email
        if [[ "$line" =~ "=> $receiver" && "$line" =~ "for $receiver" ]]; then
            echo "Email sent from $sender to $receiver at $timestamp"
            # Store sent email information in the array
            sent_emails["$sender,$receiver"]="$timestamp"
        # Check for email delivery to receiver
        elif [[ "$line" =~ "Saved" && "$line" =~ "for $receiver" ]]; then
            echo "Email delivered to $receiver at $timestamp"
            # Check for matching sender and receiver in stored data
            for key in "${!sent_emails[@]}"; do
                IFS=',' read -r stored_sender stored_receiver <<< "$key"
                if [[ "$sender" == "$stored_sender" && "$receiver" == "$stored_receiver" ]]; then
                    echo "Found match for email from $sender to $receiver"
                    # If match found, send data to API
                    subject=$(echo "$line" | grep -oP 'T="\K[^"]+')
                    curl -X POST "$api_url" \
                        -d "sender=$sender" \
                        -d "receiver=$receiver" \
                        -d "subject=$subject" \
                        -d "timestamp=$timestamp"
                    echo "Email information sent: $subject"
                    unset sent_emails["$key"]  # Remove sent email information after sending
                    break
                fi
            done
        fi
    fi
done

echo "Log processing complete."
