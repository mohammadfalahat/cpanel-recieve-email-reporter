#!/bin/bash

EMAIL_FILE="/tmp/email_$(date +%s)_$$.txt"
LOG_FILE="/tmp/filter_email.log"
MAIL_DIR="/home/shonizgl/mail/shoniz.com"
SENT_FILE="/tmp/sent_messages.txt"
GRPC_API_URL="https://your-grpc-endpoint.com/api" # Replace with your gRPC API endpoint
API_KEY="-"

# Save the incoming email to a temporary file
cat > "$EMAIL_FILE"

# Check if the email has already been processed
if grep -q "X-Processed-By: MyScript" "$EMAIL_FILE"; then
    echo "$(date): Email already processed. Skipping." >> "$LOG_FILE"
    rm -f "$EMAIL_FILE"
    exit 0
fi

# Extract Message-ID from the email
MESSAGE_ID=$(grep -i "^Message-ID:" "$EMAIL_FILE" | sed 's/^Message-ID: //I')

# Check if the Message-ID is in the sent file
if tail -n 50 "$SENT_FILE" | grep -q "$MESSAGE_ID"; then
    echo "$(date): Duplicate Message-ID found. Skipping email." >> "$LOG_FILE"
    rm -f "$EMAIL_FILE"
    exit 0
fi

# Extract email details
DATE=$(date +"%Y-%m-%d %H:%M:%S")
SUBJECT=$(grep -i "^Subject: " "$EMAIL_FILE" | sed 's/^Subject: //I')
FROM=$(grep -i "^From: " "$EMAIL_FILE" | sed 's/^From: //I')

# Extract recipients
TO=$(grep -i "^To: " "$EMAIL_FILE" | sed 's/^To: //I')
CC=$(grep -i "^Cc: " "$EMAIL_FILE" | sed 's/^Cc: //I')
BCC=$(grep -i "^Bcc: " "$EMAIL_FILE" | sed 's/^Bcc: //I')

# Process recipients into a single comma-separated list
RECIPIENTS=$(echo "$TO,$CC,$BCC" | tr -d '\r' | tr ',' '\n' | sed '/^$/d' | sed -E 's/.*<([^>]+)>.*/\1/' | tr '\n' ',' | sed 's/,$//')

# Log email details
echo "$(date): Processing email" >> "$LOG_FILE"
echo "Date: $DATE" >> "$LOG_FILE"
echo "From: $FROM" >> "$LOG_FILE"
echo "Recipients: $RECIPIENTS" >> "$LOG_FILE"
echo "Subject: $SUBJECT" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"

# Insert a custom header (X-Processed-By) between the X-YourOrg-MailScanner headers
awk '
  BEGIN { processed = 0 }
  /X-YourOrg-MailScanner-From:/ { 
    print $0; 
    if (processed == 0) { 
      print "X-Processed-By: MyScript"; 
      processed = 1; 
    } 
    next 
  }
  { print $0 }' "$EMAIL_FILE" > "${EMAIL_FILE}.processed"

# Resend the email using sendmail
sendmail -t < "${EMAIL_FILE}.processed"

# Make the gRPC API call
curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey $API_KEY" \
    -H "X-Processed-By: MyScript" \
    -d "{\"from\":\"$FROM\",\"recipients\":\"$RECIPIENTS\",\"title\":\"$SUBJECT\"}" \
    --http2 \
    "$GRPC_API_URL" >> "$LOG_FILE" 2>&1

# Store the Message-ID in the sent file to prevent duplicate emails
echo "$MESSAGE_ID" >> "$SENT_FILE"
echo "$(date): Email processed, API call made, and Message-ID stored." >> "$LOG_FILE"

# Clean up temporary files
rm -f "$EMAIL_FILE" "${EMAIL_FILE}.processed"
