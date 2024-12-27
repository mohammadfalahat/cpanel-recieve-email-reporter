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

# Store email information in variables
email_id=""
sender=""
receiver=""
subject=""
timestamp=""

# Process log lines for sent and received emails
echo "Processing log lines..."

echo "$lines" | while read line; do
    # Check email timestamp and convert to epoch
    timestamp=$(echo "$line" | grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' | head -n 1)
    timestamp_epoch=$(date -d "$timestamp" +%s)

    # If the email timestamp is within the last minute
    if [ "$timestamp_epoch" -gt "$one_minute_ago" ]; then
        # Extract the sender, receiver, subject, and email ID
        email_id=$(echo "$line" | grep -oP '^\S+')
        sender=$(echo "$line" | grep -oP '(?<=<= ).*?(?= H=)')
        receivers=$(echo "$line" | grep -oP '(?<=for ).*?(?=$| )')
        subject=$(echo "$line" | grep -oP 'T="\K[^"]+')

        # If sender, receiver(s), and subject are found, store them
        if [[ -n "$email_id" && -n "$sender" && -n "$receivers" && -n "$subject" ]]; then
            echo "Found email ID: $email_id, sender: $sender, receivers: $receivers, subject: $subject"
            stored_email_id="$email_id"
            stored_sender="$sender"
            stored_receivers="$receivers"
            stored_subject="$subject"
            stored_timestamp="$timestamp"
        fi

        # Split receivers and process each separately
        IFS=" " read -r -a receiver_array <<< "$stored_receivers"
        for stored_receiver in "${receiver_array[@]}"; do
            # Check for email delivery confirmation (either successful or to spam)
            if [[ "$line" =~ "$stored_email_id" && "$line" =~ "Saved" && "$line" =~ "for $stored_receiver" ]]; then
                if [[ ! "$line" =~ "shonizpams+spam" ]]; then
                    # Successful delivery
                    echo "Email successfully delivered to $stored_receiver at $timestamp with subject: $stored_subject"
                    curl -X POST "$api_url" \
                        -d "sender=$stored_sender" \
                        -d "receiver=$stored_receiver" \
                        -d "subject=$stored_subject" \
                        -d "timestamp=$stored_timestamp"
                    echo "Email information sent to API: $stored_subject"
                else
                    # Email delivered to spam
                    echo "Email delivered to spam for $stored_receiver: $stored_subject"
                fi
            fi
        done

        # Clear stored variables after processing
        stored_email_id=""
        stored_sender=""
        stored_receivers=""
        stored_subject=""
        stored_timestamp=""
    fi
done

echo "Log processing complete."
