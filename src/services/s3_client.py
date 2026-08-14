"""MinIO / S3-compatible object storage client."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import BinaryIO

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError

from src.services.settings import Settings, get_settings

logger = logging.getLogger(__name__)


@dataclass
class DocumentObject:
    key: str
    size: int
    last_modified: str | None
    etag: str | None = None


class S3Client:
    """Thin wrapper around boto3 for MinIO buckets used by the redaction pipeline."""

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self._client = boto3.client(
            "s3",
            endpoint_url=self.settings.s3_endpoint_url,
            aws_access_key_id=self.settings.s3_access_key,
            aws_secret_access_key=self.settings.s3_secret_key,
            region_name=self.settings.s3_region,
            use_ssl=self.settings.s3_secure,
            config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
        )

    def ensure_buckets(self, buckets: list[str] | None = None) -> None:
        targets = buckets or [
            self.settings.s3_raw_bucket,
            self.settings.s3_redacted_bucket,
            self.settings.s3_vector_bucket,
        ]
        for bucket in targets:
            try:
                self._client.head_bucket(Bucket=bucket)
                logger.info("Bucket exists: %s", bucket)
            except ClientError:
                logger.info("Creating bucket: %s", bucket)
                self._client.create_bucket(Bucket=bucket)

    def list_documents(self, bucket_name: str, prefix: str = "") -> list[DocumentObject]:
        paginator = self._client.get_paginator("list_objects_v2")
        docs: list[DocumentObject] = []
        for page in paginator.paginate(Bucket=bucket_name, Prefix=prefix):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if key.endswith("/"):
                    continue
                docs.append(
                    DocumentObject(
                        key=key,
                        size=int(obj.get("Size", 0)),
                        last_modified=obj.get("LastModified").isoformat()
                        if obj.get("LastModified")
                        else None,
                        etag=obj.get("ETag"),
                    )
                )
        return docs

    def fetch_bytes(self, bucket_name: str, file_key: str) -> bytes:
        response = self._client.get_object(Bucket=bucket_name, Key=file_key)
        return response["Body"].read()

    def upload_bytes(
        self,
        bucket_name: str,
        file_key: str,
        data: bytes,
        content_type: str = "application/pdf",
    ) -> str:
        self._client.put_object(
            Bucket=bucket_name,
            Key=file_key,
            Body=data,
            ContentType=content_type,
        )
        return f"s3://{bucket_name}/{file_key}"

    def upload_fileobj(
        self,
        bucket_name: str,
        file_key: str,
        fileobj: BinaryIO,
        content_type: str = "application/pdf",
    ) -> str:
        self._client.upload_fileobj(
            fileobj,
            bucket_name,
            file_key,
            ExtraArgs={"ContentType": content_type},
        )
        return f"s3://{bucket_name}/{file_key}"

    def object_exists(self, bucket_name: str, file_key: str) -> bool:
        try:
            self._client.head_object(Bucket=bucket_name, Key=file_key)
            return True
        except ClientError:
            return False
