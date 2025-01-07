#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <bucket-name> <kms-key-arn>"
    echo "Example: $0 my-guardduty-logs arn:aws:kms:us-east-1:account-id:key/key-id"
    exit 1
}

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    usage
fi

# Input parameters
S3_BUCKET_NAME=$1
KMS_KEY_ARN=$2

# Get all enabled AWS regions
REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text)
if [ -z "$REGIONS" ]; then
    echo "Error: Could not retrieve AWS regions. Ensure AWS CLI is configured."
    exit 1
fi

# Get current AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Error: Could not determine AWS account. Ensure AWS CLI is configured."
    exit 1
fi

# Iterate over all regions
for REGION in $REGIONS; do
    echo "Processing region: $REGION"

    # Check if the region is enabled
    REGION_STATUS=$(aws ec2 describe-regions --region-names "$REGION" --query "Regions[0].OptInStatus" --output text 2>/dev/null)
    if [ "$REGION_STATUS" != "opt-in-not-required" ] && [ "$REGION_STATUS" != "opted-in" ]; then
        echo "Region $REGION is not enabled. Skipping..."
        continue
    fi

    # Check if GuardDuty is enabled
    GUARDDUTY_DETECTOR_ID=$(aws guardduty list-detectors --region "$REGION" --query "DetectorIds[0]" --output text 2>/dev/null)
    if [ "$GUARDDUTY_DETECTOR_ID" == "None" ]; then
        echo "GuardDuty is not enabled in region $REGION. Skipping..."
        continue
    fi

    echo "GuardDuty Detector ID for region $REGION: $GUARDDUTY_DETECTOR_ID"

    # Update GuardDuty detector frequency
    echo "Updating finding publishing frequency for region $REGION..."
    aws guardduty update-detector \
        --detector-id "$GUARDDUTY_DETECTOR_ID" \
        --finding-publishing-frequency FIFTEEN_MINUTES \
        --region "$REGION"

    if [ $? -eq 0 ]; then
        echo "Successfully updated finding publishing frequency in region $REGION."
    else
        echo "Error: Failed to update finding publishing frequency in region $REGION."
    fi

    # Construct ARNs
    S3_BUCKET_ARN="arn:aws:s3:::${S3_BUCKET_NAME}"

    # Check if Findings export options are already configured
    EXISTING_DESTINATION_ID=$(aws guardduty list-publishing-destinations --detector-id "$GUARDDUTY_DETECTOR_ID" --region "$REGION" --query "Destinations[?DestinationType=='S3'].DestinationId" --output text)

    if [ -n "$EXISTING_DESTINATION_ID" ]; then
        echo "Existing publishing destination ID for region $REGION: $EXISTING_DESTINATION_ID"
        echo "GuardDuty findings export already configured for region $REGION. Deleting existing configuration..."
        aws guardduty delete-publishing-destination \
            --detector-id "$GUARDDUTY_DETECTOR_ID" \
            --destination-id "$EXISTING_DESTINATION_ID" \
            --region "$REGION"

        if [ $? -eq 0 ]; then
            echo "Successfully deleted existing publishing destination in region $REGION."
        else
            echo "Error: Failed to delete existing publishing destination in region $REGION."
            continue
        fi
    else
        echo "No existing publishing destination found for region $REGION."
    fi

    # Configure GuardDuty publishing destination
    echo "Creating new GuardDuty publishing destination in region $REGION..."
    aws guardduty create-publishing-destination \
        --detector-id "$GUARDDUTY_DETECTOR_ID" \
        --destination-type S3 \
        --destination-properties "DestinationArn=${S3_BUCKET_ARN},KmsKeyArn=${KMS_KEY_ARN}" \
        --region "$REGION"

    if [ $? -eq 0 ]; then
        echo "Successfully configured new publishing destination in region $REGION."
    else
        echo "Error: Failed to configure new publishing destination in region $REGION."
    fi

done

echo "Script execution completed."
