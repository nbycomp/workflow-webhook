#!/bin/bash

webhook_auth=${INPUT_WEBHOOK_AUTH:-$WEBHOOK_AUTH}
webhook_secret=${INPUT_WEBHOOK_SECRET:-$WEBHOOK_SECRET}
webhook_type=${INPUT_WEBHOOK_TYPE:-$WEBHOOK_TYPE}
webhook_url=${INPUT_WEBHOOK_URL:-$WEBHOOK_URL}
silent=${INPUT_SILENT:-$SILET}
verbose=${INPUT_VERBOSE:-$VERBOSE}
verify_ssl=${INPUT_VERIFY_SSL:-$VERIFY_SSL}
timeout=${INPUT_TIMEOUT:-$TIMEOUT}
max_time=${INPUT_MAX_TIME:-$MAX_TIME}
curl_opts=${INPUT_CURL_OPTS:-$CURL_OPTS}
event_name=${INPUT_EVENT_NAME:-$EVENT_NAME}
data=${INPUT_DATA:-$DATA}

urlencode() {
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            *) printf '%s' "$c" | xxd -p -c1 |
                   while read c; do printf '%%%s' "$c"; done ;;
        esac
    done
}

urldecode() {
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

set -e

if [ -z "$webhook_url" ]; then
    echo "No webhook_url configured"
    exit 1
fi

if [ -z "$webhook_secret" ]; then
    webhook_secret=$webhook_url
fi

#
# This method does not require additional package installation (of util-linux) 
# on docker image, resulting in a slightly smaller image file
#
# REQUEST_ID=$(cat /dev/urandom | tr -dc '0-9a-f' | fold -w 32 | head -n 1)

#
# This method is cleaner, but requires util-linux to be installed on Alpine image,
# resuling in a slightly larger image file
# 
REQUEST_ID=$(uuidgen)

if [ "$silent" != true ]; then
    echo "Webhook Request ID: $REQUEST_ID"
fi

if [ -n "$event_name" ]; then
    EVENT_NAME=$event_name
else
    EVENT_NAME=$GITHUB_EVENT_NAME
fi

if [ -n "$webhook_type" ] && [ "$webhook_type" == "form-urlencoded" ]; then

    EVENT=`urlencode "$EVENT_NAME"`
    REPOSITORY=`urlencode "$GITHUB_REPOSITORY"`
    COMMIT=`urlencode "$GITHUB_SHA"`
    REF=`urlencode "$GITHUB_REF"`
    HEAD=`urlencode "$GITHUB_HEAD_REF"`
    WORKFLOW=`urlencode "$GITHUB_WORKFLOW"`

    CONTENT_TYPE="application/x-www-form-urlencoded"
    WEBHOOK_DATA="event=$EVENT&repository=$REPOSITORY&commit=$COMMIT&ref=$REF&head=$HEAD&workflow=$WORKFLOW&requestID=$REQUEST_ID"

    if [ -n "$data" ]; then
        WEBHOOK_DATA="${WEBHOOK_DATA}&${data}"
    fi

else

    CONTENT_TYPE="application/json"

    if [ -n "$webhook_type" ] && [ "$webhook_type" == "json-extended" ]; then
        RAW_FILE_DATA=`cat $GITHUB_EVENT_PATH`
        WEBHOOK_DATA=$(echo -n "$RAW_FILE_DATA" | jq -c '')
    else
        WEBHOOK_DATA=$(jo event="$EVENT_NAME" repository="$GITHUB_REPOSITORY" commit="$GITHUB_SHA" ref="$GITHUB_REF" head="$GITHUB_HEAD_REF" workflow="$GITHUB_WORKFLOW")
    fi
    
    if [ -n "$data" ]; then
        CUSTOM_JSON_DATA=$(echo -n "$data" | jq -c '')
        WEBHOOK_DATA=$(jq -s '.[0] * .[1]' <(echo $WEBHOOK_DATA) <(jo requestID="$REQUEST_ID" data="$CUSTOM_JSON_DATA"))
    else
        WEBHOOK_DATA=$(jq -s '.[0] * .[1]' <(echo $WEBHOOK_DATA) <(jo requestID="$REQUEST_ID"))
    fi

fi

WEBHOOK_SIGNATURE=$(echo -n "$WEBHOOK_DATA" | openssl dgst -sha1 -hmac "$webhook_secret" -binary | xxd -p)
WEBHOOK_SIGNATURE_256=$(echo -n "$WEBHOOK_DATA" | openssl dgst -sha256 -hmac "$webhook_secret" -binary | xxd -p |tr -d '\n')
WEBHOOK_ENDPOINT=$webhook_url

if [ -n "$webhook_auth" ]; then
    WEBHOOK_ENDPOINT="-u $webhook_auth $webhook_url"
fi

options="--http1.1 --fail-with-body"

if [ "$verbose" = true ]; then
    options="$options -v"
    options="$options -sS"
elif [ "$silent" = true ]; then
    options="$options -s"
else
    # The -s disables the progress meter, as well as error messages. 
    # We want Curl to report errors, which we reenable with -S
    options="$options -sS"
fi

if [ "$verify_ssl" = false ]; then
    options="$options -k"
fi

if [ -n "$timeout" ]; then
    options="$options --connect-timeout $timeout"
fi

if [ -n "$max_time" ]; then
    options="$options --max-time $max_time"
fi

if [ -n "$curl_opts" ]; then
    options="$options $curl_opts"
fi

if [ "$verbose" = true ]; then
    echo "curl $options \\"
    echo "-H 'Content-Type: $CONTENT_TYPE' \\"
    echo "-H 'User-Agent: GitHub-Hookshot/760256b' \\"
    echo "-H 'X-Hub-Signature: sha1=$WEBHOOK_SIGNATURE' \\"
    echo "-H 'X-Hub-Signature-256: sha256=$WEBHOOK_SIGNATURE_256' \\"
    echo "-H 'X-GitHub-Delivery: $REQUEST_ID' \\"
    echo "-H 'X-GitHub-Event: $EVENT_NAME' \\"
    echo "--data '$WEBHOOK_DATA'"
fi

set +e

response=$(curl $options \
    -H "Content-Type: $CONTENT_TYPE" \
    -H "User-Agent: GitHub-Hookshot/760256b" \
    -H "X-Hub-Signature: sha1=$WEBHOOK_SIGNATURE" \
    -H "X-Hub-Signature-256: sha256=$WEBHOOK_SIGNATURE_256" \
    -H "X-GitHub-Delivery: $REQUEST_ID" \
    -H "X-GitHub-Event: $EVENT_NAME" \
    --data "$WEBHOOK_DATA" $WEBHOOK_ENDPOINT)

CURL_STATUS=$?

# echo "response-body=$response" >> $GITHUB_OUTPUT
echo "response-body<<$REQUEST_ID" >> $GITHUB_OUTPUT
echo "$response" >> $GITHUB_OUTPUT
echo "$REQUEST_ID" >> $GITHUB_OUTPUT

if [ "$verbose" = true ]; then
    echo "Webhook Response [$CURL_STATUS]:"
    echo "${response}"
fi

exit $CURL_STATUS
