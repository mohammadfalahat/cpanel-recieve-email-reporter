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
declare -A email_subjects

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

        # Extract the subject
        subject=$(echo "$line" | grep -oP 'T="\K[^"]+')

        # Check if subject is empty, if so, set it to "بدون عنوان"
        if [[ -z "$subject" ]]; then
            subject="بدون عنوان"
        fi

        # Skip if the receiver has "+spam" in their address (indicating it went to spam)
        if [[ "$receiver" =~ \+spam ]]; then
            continue
        fi

        # Store email information when sent
        if [[ -n "$sender" && -n "$receiver" && -n "$subject" ]]; then
            sent_emails["$sender,$receiver"]="$timestamp"
            email_subjects["$sender,$receiver"]="$subject"
            echo "Stored email from $sender to $receiver with subject: $subject"
        fi

        # Check for email delivery to receiver
        if [[ "$line" =~ "Saved" && "$line" =~ "for $receiver" ]]; then
            echo "Email delivered to $receiver at $timestamp"

            # Check for matching sender and receiver in stored data
            for key in "${!sent_emails[@]}"; do
                IFS=',' read -r stored_sender stored_receiver <<< "$key"
                if [[ "$sender" == "$stored_sender" && "$receiver" == "$stored_receiver" ]]; then
                    echo "Found match for email from $sender to $receiver"

                    # Use the stored subject from the email_subjects array
                    stored_subject="${email_subjects["$sender,$receiver"]}"

                    # Send data to API
                    if [[ -n "$stored_subject" ]]; then
                        curl -X POST "$api_url" \
                            -d "sender=$sender" \
                            -d "receiver=$receiver" \
                            -d "subject=$stored_subject" \
                            -d "timestamp=$timestamp"
                        echo "Email information sent: $stored_subject"
                    else
                        echo "Subject missing, not sending to API."
                    fi
                    unset sent_emails["$key"]  # Remove sent email information after sending
                    unset email_subjects["$key"]  # Remove subject from memory after sending
                    break
                fi
            done
        fi
    fi
done

echo "Log processing complete."
