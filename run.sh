#!/bin/bash

decode_utf8() {
    local encoded_text="$1"

    # Check for UTF-8 Base64 encoded text
    if [[ "$encoded_text" =~ =\?[Uu][Tt][Ff]-8\?B\?(.*)\?\= ]]; then
        local base64_text="${BASH_REMATCH[1]}"
        echo "$base64_text" | base64 --decode

    # Check for Q-encoded text (quoted-printable encoding)
    elif [[ "$encoded_text" =~ =\?([A-Za-z0-9\-]+)\?Q\?(.*)\?\= ]]; then
        local charset="${BASH_REMATCH[1]}"
        local q_encoded_text="${BASH_REMATCH[2]}"
        # Decode Q-encoding: Replace underscores with spaces, handle =XX hex sequences
        echo "$q_encoded_text" | sed 's/_/ /g' | perl -pe 's/=([0-9A-Fa-f]{2})/chr(hex($1))/eg' | iconv -f "$charset" -t utf-8

    # Check for other Base64 encoded text with specific charsets
    elif [[ "$encoded_text" =~ =\?([A-Za-z0-9\-]+)\?B\?(.*)\?\= ]]; then
        local charset="${BASH_REMATCH[1]}"
        local base64_text="${BASH_REMATCH[2]}"
        echo "$base64_text" | base64 --decode | iconv -f "$charset" -t utf-8

    # Fallback: If no encoding is detected, return as is
    else
        echo "$encoded_text"
    fi
}

EMAIL_FILE="/tmp/email_$(date +%s)_$$.txt"
LOG_FILE="/tmp/filter_email.log"
MAIL_DIR="/home/shonizgl/mail/shoniz.com"
SENT_FILE="/tmp/sent_messages.txt"
GRPC_API_URL="185.79.96.19:993" # Your gRPC API endpoint
API_KEY="---" # Replace with your API key
PROTO_FILE="/home/shonizgl/MessagingApiService.proto" # Path to the .proto file
IMPORT_PATH="/home/shonizgl" # Path to the directory containing the .proto file

# Save the incoming email to a temporary file
cat > "$EMAIL_FILE"

# Extract X-YourOrg-MailScanner-ID from the email
MESSAGE_ID=$(grep -i "^X-YourOrg-MailScanner-ID:" "$EMAIL_FILE" | sed 's/^X-YourOrg-MailScanner-ID: //I')

# Check if the X-YourOrg-MailScanner-ID is in the sent file
if tail -n 50 "$SENT_FILE" | grep -q "$MESSAGE_ID"; then
    echo "$(date): Duplicate X-YourOrg-MailScanner-ID found. Skipping email." >> "$LOG_FILE"
    rm -f "$EMAIL_FILE"
    exit 0
fi

# Extract email details
DATE=$(date +"%Y-%m-%d %H:%M:%S")

RAWSUBJECT=$(grep -i "^Subject: " "$EMAIL_FILE" | sed 's/^Subject: //I' | tr -d "\"\'\`")
FROM=$(grep -i "^From: " "$EMAIL_FILE" | sed 's/^From: //I' | sed 's/[<>\"`]*//g' | awk -F'[<>]' '{print $1 $2}' | sed 's/  */ /g')
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
        MESSAGE="شما یک ایمیل جدید از طرف $FROM \nبا موضوع \\\"$SUBJECT\\\" دریافت نموده اید.\nلطفاً برای مشاهده آن به ایمیل خود مراجعه فرمایید."
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

# Store the X-YourOrg-MailScanner-ID in the sent file to prevent duplicate emails
echo "$MESSAGE_ID" >> "$SENT_FILE"
echo "$(date): Email processed, API calls made where applicable, and X-YourOrg-MailScanner-ID stored." >> "$LOG_FILE"

# Clean up temporary files
rm -f "$EMAIL_FILE" "${EMAIL_FILE}.processed"
