import json
import os
import uuid
import re
from datetime import datetime, timezone

import boto3

S3_BUCKET = os.environ["S3_BUCKET"]
DYNAMO_TABLE = os.environ["DYNAMO_TABLE"]
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "*")
DUMP_KEY = os.environ.get("DUMP_KEY", "")

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(DYNAMO_TABLE)

EMAIL_RE = re.compile(
    r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
    r"(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$"
)

ALLOWED_SCREENINGS = {
    "Thursday, March 12 6:30pm",
    "Friday, March 13 3:15pm",
    "Saturday, March 14 10:15pm",
}

MAX_FIELD_LEN = 500


def cors_headers():
    return {
        "Access-Control-Allow-Origin": ALLOWED_ORIGINS,
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
    }


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {**cors_headers(), "Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def sanitize(value, max_len=MAX_FIELD_LEN):
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    if len(cleaned) > max_len:
        cleaned = cleaned[:max_len]
    return cleaned if cleaned else None


def get_upload_url(event):
    try:
        body = json.loads(event.get("body", "{}"))
    except (json.JSONDecodeError, TypeError):
        body = {}

    content_type = body.get("contentType", "image/jpeg")
    # Only allow image content types
    if not content_type.startswith("image/"):
        content_type = "image/jpeg"

    photo_key = f"photos/{uuid.uuid4()}.jpg"
    presigned_url = s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket": S3_BUCKET,
            "Key": photo_key,
            "ContentType": content_type,
        },
        ExpiresIn=300,
    )
    return respond(200, {"uploadUrl": presigned_url, "photoKey": photo_key, "contentType": content_type})


def submit(event):
    try:
        body = json.loads(event.get("body", "{}"))
    except (json.JSONDecodeError, TypeError):
        return respond(400, {"error": "invalid json"})

    # Required fields
    screening = sanitize(body.get("screening"))
    name = sanitize(body.get("name"))
    photo_key = sanitize(body.get("photoKey"))
    email = sanitize(body.get("email"))
    travel_location = sanitize(body.get("travelLocation"))
    travel_year = sanitize(body.get("travelYear"))
    punny_auto = body.get("punnyAuto")

    # Validate required fields
    errors = []
    if screening and screening not in ALLOWED_SCREENINGS:
        errors.append("invalid screening selection")
    if not name:
        errors.append("name is required")
    if not photo_key or not photo_key.startswith("photos/"):
        errors.append("invalid photo key")
    if not email or not EMAIL_RE.match(email):
        errors.append("valid email is required")
    if not travel_location:
        errors.append("travel location is required")
    if not travel_year:
        errors.append("travel year is required")
    if not isinstance(punny_auto, bool):
        errors.append("punnyAuto must be a boolean")

    # If they chose to pick their own punny name, it's required
    punny_name = None
    if punny_auto is False:
        punny_name = sanitize(body.get("punnyName"))
        if not punny_name:
            errors.append("punny name is required when choosing your own")

    if errors:
        return respond(400, {"error": "; ".join(errors)})

    # Verify photo exists in S3
    try:
        s3.head_object(Bucket=S3_BUCKET, Key=photo_key)
    except s3.exceptions.ClientError:
        return respond(400, {"error": "photo not found — please re-upload"})

    # Save to DynamoDB
    submission_id = str(uuid.uuid4())
    item = {
        "id": submission_id,
        "name": name,
        "photoKey": photo_key,
        "punnyAuto": punny_auto,
        "travelLocation": travel_location,
        "travelYear": travel_year,
        "email": email,
        "submittedAt": datetime.now(timezone.utc).isoformat(),
    }
    if screening:
        item["screening"] = screening
    if punny_name:
        item["punnyName"] = punny_name

    table.put_item(Item=item)

    return respond(200, {"success": True, "id": submission_id})


def dump(event):
    # Verify API key
    params = event.get("queryStringParameters") or {}
    key = params.get("key", "")
    if not DUMP_KEY or key != DUMP_KEY:
        return respond(403, {"error": "unauthorized"})

    # Scan all submissions
    items = []
    response = table.scan()
    items.extend(response.get("Items", []))
    while "LastEvaluatedKey" in response:
        response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
        items.extend(response.get("Items", []))

    # Sort by submission time
    items.sort(key=lambda x: x.get("submittedAt", ""))

    # Generate presigned GET URLs for photos (valid 7 days)
    for item in items:
        photo_key = item.get("photoKey", "")
        if photo_key:
            item["photoUrl"] = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET, "Key": photo_key},
                ExpiresIn=604800,
            )
        # Convert booleans for JSON serialization
        if "punnyAuto" in item:
            item["punnyAuto"] = bool(item["punnyAuto"])

    return respond(200, {"submissions": items, "count": len(items)})


def lambda_handler(event, context):
    # Handle CORS preflight
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    if method == "OPTIONS":
        return respond(200, {})

    path = event.get("rawPath", "")

    if path == "/upload-url" and method == "POST":
        return get_upload_url(event)
    elif path == "/submit" and method == "POST":
        return submit(event)
    elif path == "/dump" and method == "GET":
        return dump(event)
    else:
        return respond(404, {"error": "not found"})
