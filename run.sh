#!/bin/bash

decode_utf8() {
    local encoded_text="$1"
    if [[ "$encoded_text" =~ =\?[Uu][Tt][Ff]-8\?B\?(.*)\?\= ]]; then
        local base64_text="${BASH_REMATCH[1]}"
        echo "$base64_text" | base64 --decode
    else
        echo "$encoded_text"
    fi
}


EMAIL_FILE="/tmp/email_$(date +%s)_$$.txt"
LOG_FILE="/tmp/filter_email.log"
MAIL_DIR="/home/shonizgl/mail/shoniz.com"
SENT_FILE="/tmp/sent_messages.txt"
GRPC_API_URL="185.79.96.19:993" # Your gRPC API endpoint
API_KEY="BCRSinvRAU4hheWx1hqg2S0Rb1iMP9U2pBqhgcW1hzXDtgP9l2" # Replace with your API key
PROTO_FILE="/home/shonizgl/MessagingApiService.proto" # Path to the .proto file
IMPORT_PATH="/home/shonizgl" # Path to the directory containing the .proto file

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

RAWSUBJECT=$(grep -i "^Subject: " "$EMAIL_FILE" | sed 's/^Subject: //I' | tr -d "\"\'\`")
FROM=$(grep -i "^From: " "$EMAIL_FILE" | sed 's/^From: //I' | tr -d "\"\'\`" )
SUBJECT=$(decode_utf8 "$RAWSUBJECT")

# Extract recipients
TO=$(grep -i "^To: " "$EMAIL_FILE" | sed 's/^To: //I')
CC=$(grep -i "^Cc: " "$EMAIL_FILE" | sed 's/^Cc: //I')
BCC=$(grep -i "^Bcc: " "$EMAIL_FILE" | sed 's/^Bcc: //I')

# Process recipients into a single newline-separated list
ALL_RECIPIENTS=$(echo "$TO,$CC,$BCC" | tr -d '\r' | tr ',' '\n' | sed '/^$/d' | sed -E 's/.*<([^>]+)>.*/\1/')

# Log email details
echo "$(date): Processing email" >> "$LOG_FILE"
echo "Date: $DATE" >> "$LOG_FILE"
echo "From: $FROM" >> "$LOG_FILE"
echo "Recipients: $ALL_RECIPIENTS" >> "$LOG_FILE"
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
echo "$(date): Email sent using sendmail." >> "$LOG_FILE"

# Make a gRPC API call for each recipient with @shoniz.com
echo "$ALL_RECIPIENTS" | while read -r RECIPIENT; do
    if [[ "$RECIPIENT" == *@shoniz.com ]]; then
        echo "$(date): Making API call for recipient: $RECIPIENT" >> "$LOG_FILE"

        # Create the gRPC payload
        FROM=$(echo "$FROM" | sed 's/[<>]//g')
        MESSAGE="ﺶﻣﺍ ﯽﮐ ﺎﯿﻤﯿﻟ ﺝﺪﯾﺩ ﺍﺯ ﻁﺮﻓ $FROM \nﺏﺍ ﻡﻮﺿﻮﻋ \\\"$SUBJECT\\\" ﺩﺮﯾﺎﻔﺗ ﻦﻣﻭﺪﻫ ﺎﯾﺩ.\nﻞﻄﻓﺍً ﺏﺭﺎﯾ ﻢﺷﺎﻫﺪﻫ ﺂﻧ ﺐﻫ ﺎﯿﻤﯿﻟ ﺥﻭﺩ ﻡﺭﺎﺠﻌﻫ ﻑﺮﻣﺎﯿﯾﺩ."
        PAYLOAD=$(cat <<EOF
{
  "Email": "$RECIPIENT",
  "Message": "$MESSAGE"
}
EOF
)

        # Make the API call using grpcurl
        /root/go/bin/grpcurl -plaintext \
            -H "x-api-key: $API_KEY" \
            -d "$PAYLOAD" \
            -proto $PROTO_FILE \
            -import-path $IMPORT_PATH \
            $GRPC_API_URL Ding.Contract.Messaging.MessagingApiService/NotifyMessage >> "$LOG_FILE" 2>&1

        echo "$(date): API call completed for recipient: $RECIPIENT" >> "$LOG_FILE"
    else
        echo "$(date): Skipping API call for recipient: $RECIPIENT (not @shoniz.com)" >> "$LOG_FILE"
    fi
done

# Store the Message-ID in the sent file to prevent duplicate emails
echo "$MESSAGE_ID" >> "$SENT_FILE"
echo "$(date): Email processed, API calls made where applicable, and Message-ID stored." >> "$LOG_FILE"

# Clean up temporary files
rm -f "$EMAIL_FILE" "${EMAIL_FILE}.processed"
