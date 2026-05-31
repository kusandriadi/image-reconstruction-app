"""Automatic cleanup service for old uploaded and output files.

This module provides the CleanupService class that automatically removes old files
from upload and output directories based on configurable age thresholds.
"""
from __future__ import annotations

import logging
import threading
import time
from pathlib import Path
from typing import Optional

# Get logger
logger = logging.getLogger("image_reconstruction.cleanup")


class CleanupService:
    """Background service for automatic cleanup of old files.

    This service runs in a background thread and periodically removes files
    older than a specified age from the uploads and outputs directories.

    Attributes:
        uploads_dir: Directory containing uploaded input images.
        outputs_dir: Directory containing processed output images.
        jobs_dir: Directory containing job metadata JSON files.
        interval_hours: How often to run cleanup (in hours).
        max_age_hours: Maximum age of files before deletion (in hours).
        enabled: Whether cleanup is enabled.
    """

    def __init__(
        self,
        uploads_dir: str,
        outputs_dir: str,
        jobs_dir: str = None,
        interval_hours: float = 1.0,
        max_age_hours: float = 1.0,
        enabled: bool = True,
        job_manager=None
    ):
        """Initialize the cleanup service.

        Args:
            uploads_dir: Directory path containing uploaded files.
            outputs_dir: Directory path containing output files.
            jobs_dir: Directory path containing job metadata files (optional).
            interval_hours: Interval between cleanup runs in hours (default: 1.0).
            max_age_hours: Maximum file age in hours before deletion (default: 1.0).
            enabled: Whether to enable automatic cleanup (default: True).
            job_manager: Optional JobManager. When provided, job metadata is pruned
                via job_manager.prune_old() so its in-memory table stays consistent
                with disk, instead of deleting job files directly.
        """
        self.uploads_dir = Path(uploads_dir)
        self.outputs_dir = Path(outputs_dir)
        self.jobs_dir = Path(jobs_dir) if jobs_dir else Path(outputs_dir).parent / "jobs"
        self.interval_hours = interval_hours
        self.max_age_hours = max_age_hours
        self.enabled = enabled
        self.job_manager = job_manager

        self._running = False
        self._thread: Optional[threading.Thread] = None

        logger.info(
            f"CleanupService initialized: enabled={enabled}, "
            f"interval={interval_hours}h, max_age={max_age_hours}h, "
            f"jobs_dir={self.jobs_dir}"
        )

    def start(self) -> None:
        """Start the cleanup service in a background thread."""
        if not self.enabled:
            logger.info("CleanupService is disabled, not starting")
            return

        if self._running:
            logger.warning("CleanupService already running")
            return

        self._running = True
        self._thread = threading.Thread(target=self._cleanup_loop, daemon=True)
        self._thread.start()
        logger.info("CleanupService started")

    def stop(self) -> None:
        """Stop the cleanup service."""
        if not self._running:
            return

        self._running = False
        if self._thread:
            self._thread.join(timeout=5.0)
        logger.info("CleanupService stopped")

    def _cleanup_loop(self) -> None:
        """Main cleanup loop that runs in background thread."""
        while self._running:
            try:
                self._cleanup_old_files()
            except Exception as e:
                logger.error(f"Error during cleanup: {e}", exc_info=True)

            # Sleep in small increments to allow quick shutdown
            sleep_seconds = self.interval_hours * 3600
            elapsed = 0
            while self._running and elapsed < sleep_seconds:
                time.sleep(1)
                elapsed += 1

    def _cleanup_old_files(self) -> None:
        """Remove files older than max_age_hours from configured directories."""
        max_age_seconds = self.max_age_hours * 3600
        current_time = time.time()

        # Prune job metadata via the JobManager so its in-memory table stays in
        # sync; fall back to direct file deletion only if no manager is wired in.
        directories = [self.uploads_dir, self.outputs_dir]
        if self.job_manager is not None:
            self.job_manager.prune_old(max_age_seconds)
        else:
            directories.append(self.jobs_dir)

        for directory in directories:
            if not directory.exists():
                logger.warning(f"Directory does not exist: {directory}")
                continue

            try:
                deleted_count = 0
                for file_path in directory.iterdir():
                    if not file_path.is_file():
                        continue

                    file_age = current_time - file_path.stat().st_mtime
                    if file_age > max_age_seconds:
                        try:
                            file_path.unlink()
                            deleted_count += 1
                            logger.debug(f"Deleted old file: {file_path.name} (age: {file_age/3600:.1f}h)")
                        except Exception as e:
                            logger.error(f"Failed to delete {file_path}: {e}")

                if deleted_count > 0:
                    logger.info(f"Cleaned up {deleted_count} old files from {directory}")

            except Exception as e:
                logger.error(f"Error cleaning directory {directory}: {e}", exc_info=True)

    def cleanup_now(self) -> None:
        """Trigger an immediate cleanup (useful for testing or manual cleanup)."""
        logger.info("Manual cleanup triggered")
        self._cleanup_old_files()
