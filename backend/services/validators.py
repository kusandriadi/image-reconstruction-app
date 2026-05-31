"""File upload validation and sanitization for image reconstruction API.

This module provides the UploadValidator class that validates uploaded image files
for size, MIME type, and integrity. It also handles filename sanitization for security.
"""
from __future__ import annotations

import io
import logging
from pathlib import Path
from typing import Set

from fastapi import HTTPException, UploadFile
from PIL import Image, UnidentifiedImageError

# Get logger
logger = logging.getLogger("image_reconstruction.validators")


class UploadValidator:
    """Validator for uploaded image files.

    This class validates uploaded images against configurable constraints including
    file size limits, allowed MIME types, and allowed file extensions. It also
    verifies that uploaded files are valid, decodable images and sanitizes filenames
    to prevent security issues.

    Security Features:
        - Filename sanitization removes dangerous characters
        - MIME type validation prevents malicious file uploads
        - Image integrity check ensures files are valid images
        - File size limits prevent DoS attacks

    Attributes:
        allowed_mime: Set of allowed MIME types (e.g., {"image/png", "image/jpeg"}).
        allowed_ext: Set of allowed file extensions (e.g., {".png", ".jpg"}).
        max_bytes: Maximum allowed file size in bytes.
        uploads_dir: Directory where validated files will be saved.

    Example:
        >>> validator = UploadValidator(
        ...     allowed_mime={"image/png", "image/jpeg"},
        ...     allowed_ext={".png", ".jpg"},
        ...     max_bytes=10 * 1024 * 1024,  # 10 MB
        ...     uploads_dir=Path("uploads/")
        ... )
        >>> upload_path = await validator.save(job_id="abc123", file=uploaded_file)
    """

    def __init__(self, allowed_mime: Set[str], allowed_ext: Set[str], max_bytes: int, uploads_dir: Path):
        """Initialize the upload validator with constraints.

        Args:
            allowed_mime: Set of allowed MIME types for validation.
            allowed_ext: Set of allowed file extensions (must include dot, e.g., ".png").
            max_bytes: Maximum file size in bytes.
            uploads_dir: Directory path where validated files will be saved.
        """
        self.allowed_mime = allowed_mime
        self.allowed_ext = allowed_ext
        self.max_bytes = max_bytes
        self.uploads_dir = uploads_dir

    @staticmethod
    def sanitize_filename(name: str, allowed_ext: Set[str]) -> str:
        """Sanitize filename to prevent security issues.

        Removes or replaces dangerous characters from the filename, keeping only
        alphanumeric characters, dots, underscores, and hyphens. If the resulting
        extension is not in the allowed set, it defaults to .png.

        Args:
            name: Original filename from user upload.
            allowed_ext: Set of allowed file extensions.

        Returns:
            Sanitized filename safe for filesystem storage.

        Example:
            >>> UploadValidator.sanitize_filename(
            ...     "../../etc/passwd.jpg",
            ...     {".jpg", ".png"}
            ... )
            '______etc_passwd.jpg'
            >>> UploadValidator.sanitize_filename(
            ...     "photo.webp",
            ...     {".jpg", ".png"}
            ... )
            'photo.png'
        """
        base = Path(name).name
        safe = []
        for ch in base:
            safe.append(ch if (ch.isalnum() or ch in {'.', '_', '-'}) else '_')
        result = ''.join(safe)
        ext = Path(result).suffix.lower()
        if ext not in allowed_ext:
            result = Path(result).stem + '.png'
        return result

    def _check_size(self, content: bytes):
        """Validate file size is within allowed limits.

        Args:
            content: Raw file content bytes.

        Raises:
            HTTPException 400: If file is empty.
            HTTPException 413: If file exceeds maximum size limit.
        """
        if len(content) == 0:
            raise HTTPException(status_code=400, detail="Empty file")
        if len(content) > self.max_bytes:
            raise HTTPException(status_code=413, detail="File too large")

    def _check_type(self, content_type: str | None):
        """Validate MIME type is present and in the allowed list.

        A missing Content-Type is rejected rather than silently accepted, so the
        MIME check cannot be bypassed simply by omitting the header.

        Args:
            content_type: MIME type from upload headers.

        Raises:
            HTTPException 415: If MIME type is missing or not in allowed_mime set.
        """
        if not content_type or content_type not in self.allowed_mime:
            raise HTTPException(status_code=415, detail=f"Unsupported media type: {content_type or 'missing'}")

    def _check_image_decodable(self, content: bytes):
        """Verify that the uploaded file is a valid, decodable image.

        Uses PIL to attempt opening and verifying the image. This prevents
        malicious files masquerading as images from being processed.

        Args:
            content: Raw file content bytes.

        Raises:
            HTTPException 400: If file cannot be decoded as a valid image.
        """
        try:
            Image.open(io.BytesIO(content)).verify()
        except UnidentifiedImageError:
            raise HTTPException(status_code=400, detail="Invalid image file")

    async def save(self, job_id: str, file: UploadFile) -> Path:
        """Validate and save an uploaded image file.

        Performs comprehensive validation including MIME type check, size limit
        enforcement, and image integrity verification. Sanitizes the filename and
        saves the file with a job ID prefix for uniqueness.

        Args:
            job_id: Unique job identifier to prefix the filename.
            file: FastAPI UploadFile object from multipart/form-data request.

        Returns:
            Path object pointing to the saved file location.

        Raises:
            HTTPException 400: If file is missing, empty, or invalid image format.
            HTTPException 413: If file exceeds size limit.
            HTTPException 415: If MIME type is not allowed.

        Example:
            >>> upload_path = await validator.save(
            ...     job_id="abc123",
            ...     file=uploaded_file
            ... )
            >>> print(upload_path)
            Path('uploads/abc123_photo.png')
        """
        logger.info(f"Validating upload for job {job_id}: {file.filename}")

        if not file.filename:
            logger.warning(f"Job {job_id}: No filename provided")
            raise HTTPException(status_code=400, detail="No file uploaded")

        # Validate MIME type
        self._check_type(file.content_type)

        # Read and validate content
        content = await file.read()
        file_size_mb = len(content) / (1024 * 1024)
        logger.debug(f"Job {job_id}: File size: {file_size_mb:.2f}MB")

        self._check_size(content)
        self._check_image_decodable(content)

        # Sanitize filename and prefix with job ID for uniqueness
        original_name = self.sanitize_filename(file.filename, self.allowed_ext)
        upload_path = self.uploads_dir / f"{job_id}_{original_name}"

        logger.info(f"Job {job_id}: Saving upload to {upload_path}")
        with open(upload_path, 'wb') as f:
            f.write(content)

        logger.info(f"Job {job_id}: Upload validated and saved successfully")
        return upload_path

