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
        echo "$q_encoded_text" \
          | sed 's/_/ /g' \
          | perl -pe 's/=([0-9A-Fa-f]{2})/chr(hex($1))/eg' \
          | iconv -f "$charset" -t utf-8

    # Other Base64 with specific charset
    elif [[ "$encoded_text" =~ =\?([A-Za-z0-9\-]+)\?B\?(.*)\?\= ]]; then
        local charset="${BASH_REMATCH[1]}"
        local base64_text="${BASH_REMATCH[2]}"
        echo "$base64_text" | base64 --decode | iconv -f "$charset" -t utf-8

    else
        echo "$encoded_text"
    fi
}

EMAIL_FILE="/tmp/email_$(date +%s)_$$.txt"
LOG_FILE="/tmp/filter_email.log"
MAIL_DIR="/home/shonizgl/mail/shoniz.com"
SENT_FILE="/tmp/sent_messages.txt"
MSG_IDS="/tmp/message_ids.txt"
GRPC_API_URL="31.7.65.195:993"          # Your gRPC API endpoint
API_KEY="---"                          # Replace with your API key
PROTO_FILE="/home/shonizgl/MessagingApiService.proto"
IMPORT_PATH="/home/shonizgl"

# Ensure tracking files exist
touch "$SENT_FILE" "$MSG_IDS"

# Save the incoming email
cat > "$EMAIL_FILE"

# Extract MailScanner ID
MESSAGE_ID=$(grep -i "^X-YourOrg-MailScanner-ID:" "$EMAIL_FILE" \
    | sed 's/^X-YourOrg-MailScanner-ID: //I')

# Skip if this MailScanner-ID was sent already
if tail -n 2000 "$SENT_FILE" | grep -qF "$MESSAGE_ID"; then
    echo "$(date): Duplicate X-YourOrg-MailScanner-ID found. Skipping email." >> "$LOG_FILE"
    rm -f "$EMAIL_FILE"
    exit 0
fi

# Extract Message-ID (without <>)
ALT_MSG_ID=$(grep -i "^Message-ID:" "$EMAIL_FILE" \
            | sed 's/Message-ID:[[:space:]]*//I' \
            | tr -d '<>' \
            | tr -d '[:space:]')

# Skip if this Message-ID was sent already
if tail -n 2000 "$MSG_IDS" | grep -qF "$ALT_MSG_ID"; then
    echo "$(date): Duplicate Message-ID ($ALT_MSG_ID) found. Skipping email." >> "$LOG_FILE"
    rm -f "$EMAIL_FILE"
    exit 0
fi

# Insert X-Processed-By after MailScanner-From and strip Resent-* headers
awk '
  BEGIN { processed = 0 }
  /X-YourOrg-MailScanner-From:/ {
    print $0
    if (processed == 0) {
      print "X-Processed-By: MyScript"
      processed = 1
    }
    next
  }
  { print $0 }
' "$EMAIL_FILE" | sed '/^Resent-/d' > "${EMAIL_FILE}.processed"

# Resend via sendmail
sendmail -t < "${EMAIL_FILE}.processed"
echo "$(date): Email sent using sendmail." >> "$LOG_FILE"

# Extract envelope info
DATE=$(date +"%Y-%m-%d %H:%M:%S")
RAWSUBJECT=$(grep -i "^Subject: " "$EMAIL_FILE" \
    | sed 's/^Subject: //I' | tr -d "\"\'\`")
FROM=$(grep -i "^From: " "$EMAIL_FILE" \
    | sed 's/^From: //I' \
    | sed 's/[<>\"`]*//g' \
    | awk -F'[<>]' '{print $1 $2}' \
    | sed 's/  */ /g')
SUBJECT=$(decode_utf8 "$RAWSUBJECT")

# —————————————— استخراج گیرنده‌ها ——————————————

# 1) بلوک هدر تا اولین خط خالی
HEADER_BLOCK=$(sed -n '1,/^$/p' "$EMAIL_FILE")

# 2) فقط اولین To, Cc و Bcc با ادامه‌خط‌هایشان
RECIP_HEADER_LINES=$(echo "$HEADER_BLOCK" | awk '
  BEGIN { to=cc=bcc=0; in=0 }
/^To:/ && to==0    { line=$0; to=1; in=1; next }
/^Cc:/ && cc==0    { line=$0; cc=1; in=1; next }
/^Bcc:/ && bcc==0  { line=$0; bcc=1; in=1; next }
/^[ \t]/ && in     { line = line " " $0; next }
in                  { print line; in=0 }
END { if(in) print line }
')

# 3) تفکیک بر اساس کاما، بیرون‌کِش ایمیل‌ها و حذف تکراری‌ها
ALL_RECIPIENTS=$(echo "$RECIP_HEADER_LINES" \
  | tr ',' '\n' \
  | sed -E 's/.*<([^>]+)>.*/\1/; s/^[ \t]+|[ \t]+$//g' \
  | grep -E '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
  | sort -u
)

# Log header
{
  echo "$(date): Processing email"
  echo "Date: $DATE"
  echo "From: $FROM"
  echo "MailScanner-ID: $MESSAGE_ID"
  echo "Message-ID: $ALT_MSG_ID"
  echo "Recipients:"
  echo "$ALL_RECIPIENTS"
  echo "Subject: $SUBJECT"
  echo "---"
} >> "$LOG_FILE"

# gRPC call per recipient
echo "$ALL_RECIPIENTS" | while read -r RECIPIENT; do
    RECIPIENT_ID="${MESSAGE_ID}_${RECIPIENT}"

    # Skip if already processed for this recipient
    if tail -n 200 "$MSG_IDS" | grep -qF "$RECIPIENT_ID"; then
        echo "$(date): Duplicate for recipient $RECIPIENT. Skipping API call." >> "$LOG_FILE"
        continue
    fi

    if [[ "$RECIPIENT" == *@shoniz.com ]]; then
        echo "$(date): Making API call for recipient: $RECIPIENT" >> "$LOG_FILE"

        MESSAGE="شما یک ایمیل جدید از طرف $FROM \nبا موضوع \\\"$SUBJECT\\\" دریافت نموده اید.\nلطفاً برای مشاهده آن به ایمیل خود مراجعه فرمایید."

        PAYLOAD=$(cat <<EOF
{
  "Email": "$RECIPIENT",
  "Message": "$MESSAGE"
}
EOF
)

        /root/go/bin/grpcurl -plaintext \
            -H "x-api-key: $API_KEY" \
            -d "$PAYLOAD" \
            -proto "$PROTO_FILE" \
            -import-path "$IMPORT_PATH" \
            "$GRPC_API_URL" Ding.Contract.Messaging.MessagingApiService/NotifyMessage \
        >> "$LOG_FILE" 2>&1

        echo "$(date): API call completed for recipient: $RECIPIENT" >> "$LOG_FILE"

        # Record per-recipient ID
        echo "$RECIPIENT_ID" >> "$MSG_IDS"
        echo "$(date): Recorded RECIPIENT_ID $RECIPIENT_ID in $MSG_IDS" >> "$LOG_FILE"
    else
        echo "$(date): Skipping API call for recipient: $RECIPIENT (not @shoniz.com)" >> "$LOG_FILE"
    fi
done

# Finally, record the MailScanner-ID and Message-ID
echo "$MESSAGE_ID" >> "$SENT_FILE"
echo "$ALT_MSG_ID" >> "$MSG_IDS"

echo "$(date): Email processed and IDs stored." >> "$LOG_FILE"

# Cleanup
rm -f "$EMAIL_FILE" "${EMAIL_FILE}.processed"
