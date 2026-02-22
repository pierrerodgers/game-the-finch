#!/bin/bash
set -euo pipefail

# ── Config ──────────────────────────────────────────
REGION="us-east-1"
BUCKET_NAME="sparks-id-photos-gtf"
TABLE_NAME="sparks-id-submissions"
ROLE_NAME="sparks-id-lambda-role"
FUNCTION_NAME="sparks-id-handler"
API_NAME="sparks-id-api"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")

echo "Deploying Sparks ID backend to $REGION (account: $ACCOUNT_ID)"
echo "────────────────────────────────────────────────"

# ── 1. S3 Bucket ───────────────────────────────────
echo "[1/7] Creating S3 bucket..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
    echo "  Bucket $BUCKET_NAME already exists, skipping."
else
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --no-cli-pager
    echo "  Created bucket: $BUCKET_NAME"
fi

# Set CORS on S3 bucket (allows browser to PUT photos directly)
aws s3api put-bucket-cors \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --cors-configuration '{
        "CORSRules": [{
            "AllowedHeaders": ["*"],
            "AllowedMethods": ["PUT"],
            "AllowedOrigins": ["*"],
            "ExposeHeaders": [],
            "MaxAgeSeconds": 3600
        }]
    }' \
    --no-cli-pager
echo "  CORS configured on S3 bucket."

# Block public access (photos accessed only via presigned URLs)
aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    --no-cli-pager
echo "  Public access blocked."

# ── 2. DynamoDB Table ──────────────────────────────
echo "[2/7] Creating DynamoDB table..."
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" --no-cli-pager 2>/dev/null; then
    echo "  Table $TABLE_NAME already exists, skipping."
else
    aws dynamodb create-table \
        --table-name "$TABLE_NAME" \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION" \
        --no-cli-pager
    echo "  Created table: $TABLE_NAME"
    echo "  Waiting for table to be active..."
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
    echo "  Table active."
fi

# ── 3. IAM Role ───────────────────────────────────
echo "[3/7] Creating IAM role..."
TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}'

ROLE_ARN=""
if aws iam get-role --role-name "$ROLE_NAME" --no-cli-pager 2>/dev/null; then
    echo "  Role $ROLE_NAME already exists, skipping creation."
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
else
    ROLE_ARN=$(aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --query 'Role.Arn' \
        --output text \
        --no-cli-pager)
    echo "  Created role: $ROLE_ARN"
fi

# Attach inline policy for S3 + DynamoDB + CloudWatch
INLINE_POLICY=$(cat <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:HeadObject"
            ],
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:GetItem"
            ],
            "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:*"
        }
    ]
}
POLICY
)

aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "sparks-id-policy" \
    --policy-document "$INLINE_POLICY" \
    --no-cli-pager
echo "  Inline policy attached."

# Wait for role to propagate
echo "  Waiting for IAM role to propagate..."
sleep 10

# ── 4. Lambda Function ────────────────────────────
echo "[4/7] Creating Lambda function..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAMBDA_DIR="$SCRIPT_DIR/lambda"
ZIP_FILE="/tmp/sparks-id-lambda.zip"

# Package the function
cd "$LAMBDA_DIR"
zip -j "$ZIP_FILE" handler.py
cd "$SCRIPT_DIR"

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" --no-cli-pager 2>/dev/null; then
    echo "  Function exists, updating code..."
    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file "fileb://$ZIP_FILE" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
    # Also update env vars
    aws lambda update-function-configuration \
        --function-name "$FUNCTION_NAME" \
        --environment "Variables={S3_BUCKET=$BUCKET_NAME,DYNAMO_TABLE=$TABLE_NAME,ALLOWED_ORIGINS=*}" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
    echo "  Function updated."
else
    aws lambda create-function \
        --function-name "$FUNCTION_NAME" \
        --runtime python3.12 \
        --handler handler.lambda_handler \
        --role "$ROLE_ARN" \
        --zip-file "fileb://$ZIP_FILE" \
        --timeout 15 \
        --memory-size 128 \
        --environment "Variables={S3_BUCKET=$BUCKET_NAME,DYNAMO_TABLE=$TABLE_NAME,ALLOWED_ORIGINS=*}" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
    echo "  Created function: $FUNCTION_NAME"
fi

rm -f "$ZIP_FILE"

# Wait for function to be active
echo "  Waiting for function to be active..."
aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null || sleep 5

# ── 5. API Gateway HTTP API ───────────────────────
echo "[5/7] Creating API Gateway..."
API_ID=""
EXISTING_API=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='$API_NAME'].ApiId" --output text --no-cli-pager)

if [ -n "$EXISTING_API" ] && [ "$EXISTING_API" != "None" ]; then
    API_ID="$EXISTING_API"
    echo "  API $API_NAME already exists ($API_ID), skipping creation."
else
    API_ID=$(aws apigatewayv2 create-api \
        --name "$API_NAME" \
        --protocol-type HTTP \
        --cors-configuration '{
            "AllowOrigins": ["*"],
            "AllowMethods": ["POST", "OPTIONS"],
            "AllowHeaders": ["Content-Type"],
            "MaxAge": 3600
        }' \
        --region "$REGION" \
        --query 'ApiId' \
        --output text \
        --no-cli-pager)
    echo "  Created API: $API_ID"
fi

# ── 6. Lambda Integration + Routes ────────────────
echo "[6/7] Setting up routes..."
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"

# Create or get integration
INTEGRATION_ID=$(aws apigatewayv2 get-integrations \
    --api-id "$API_ID" \
    --region "$REGION" \
    --query "Items[?IntegrationUri=='${LAMBDA_ARN}'].IntegrationId | [0]" \
    --output text \
    --no-cli-pager)

if [ -z "$INTEGRATION_ID" ] || [ "$INTEGRATION_ID" = "None" ]; then
    INTEGRATION_ID=$(aws apigatewayv2 create-integration \
        --api-id "$API_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "$LAMBDA_ARN" \
        --payload-format-version "2.0" \
        --region "$REGION" \
        --query 'IntegrationId' \
        --output text \
        --no-cli-pager)
    echo "  Created integration: $INTEGRATION_ID"
else
    echo "  Integration exists: $INTEGRATION_ID"
fi

TARGET="integrations/$INTEGRATION_ID"

# Create routes (idempotent — skip if exists)
for ROUTE_KEY in "POST /upload-url" "POST /submit"; do
    EXISTING_ROUTE=$(aws apigatewayv2 get-routes \
        --api-id "$API_ID" \
        --region "$REGION" \
        --query "Items[?RouteKey=='${ROUTE_KEY}'].RouteId | [0]" \
        --output text \
        --no-cli-pager)

    if [ -z "$EXISTING_ROUTE" ] || [ "$EXISTING_ROUTE" = "None" ]; then
        aws apigatewayv2 create-route \
            --api-id "$API_ID" \
            --route-key "$ROUTE_KEY" \
            --target "$TARGET" \
            --region "$REGION" \
            --no-cli-pager > /dev/null
        echo "  Created route: $ROUTE_KEY"
    else
        echo "  Route exists: $ROUTE_KEY"
    fi
done

# Create default stage with auto-deploy
EXISTING_STAGE=$(aws apigatewayv2 get-stages \
    --api-id "$API_ID" \
    --region "$REGION" \
    --query "Items[?StageName=='\$default'].StageName | [0]" \
    --output text \
    --no-cli-pager)

if [ -z "$EXISTING_STAGE" ] || [ "$EXISTING_STAGE" = "None" ]; then
    aws apigatewayv2 create-stage \
        --api-id "$API_ID" \
        --stage-name '$default' \
        --auto-deploy \
        --region "$REGION" \
        --no-cli-pager > /dev/null
    echo "  Created \$default stage with auto-deploy."
else
    echo "  \$default stage already exists."
fi

# ── 7. Lambda Permission ──────────────────────────
echo "[7/7] Adding Lambda invoke permission..."
aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "apigateway-invoke-${API_ID}" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
    --region "$REGION" \
    --no-cli-pager 2>/dev/null || echo "  Permission already exists."

# ── Done ──────────────────────────────────────────
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo ""
echo "════════════════════════════════════════════════"
echo "  Deployment complete!"
echo ""
echo "  API URL: $API_URL"
echo ""
echo "  Endpoints:"
echo "    POST ${API_URL}/upload-url"
echo "    POST ${API_URL}/submit"
echo ""
echo "  Next step: paste this API URL into your"
echo "  sparksid/index.html (API_BASE variable)"
echo "════════════════════════════════════════════════"
