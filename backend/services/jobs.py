"""Job queue management for asynchronous image reconstruction tasks.

This module provides the JobManager class that handles the lifecycle of reconstruction
jobs including queueing, execution in background threads, status tracking, progress
reporting, and cancellation. Jobs are persisted to disk to survive restarts.
"""
from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Dict, Optional, Callable

from .reconstructor import Reconstructor, Cancelled

# Get logger
logger = logging.getLogger("image_reconstruction.jobs")


class JobManager:
    """Asynchronous job queue manager for image reconstruction tasks.

    This class manages the complete lifecycle of reconstruction jobs using background
    worker threads. It provides thread-safe operations for job creation, status tracking,
    progress updates, and cancellation. Each job runs in its own daemon thread.

    Job States:
        - queued: Job is waiting to start
        - running: Job is currently processing
        - completed: Job finished successfully
        - failed: Job encountered an error
        - cancelled: Job was cancelled by user
        - cancelling: Job is in the process of being cancelled

    Attributes:
        reconstructor: The Reconstructor instance used for processing.
        uploads_dir: Directory containing uploaded input images.
        outputs_dir: Directory where reconstructed images are saved.
        jobs_dir: Directory where job metadata is persisted to disk.

    Thread Safety:
        All public methods are thread-safe and can be called concurrently from
        multiple threads. Internal state is protected by a threading.Lock.

    Example:
        >>> reconstructor = Reconstructor(model_path="model.pth")
        >>> manager = JobManager(reconstructor, "uploads/", "outputs/")
        >>> manager.enqueue(job_id="abc123", input_path="uploads/abc123_image.png")
        >>> status = manager.get("abc123")
        >>> print(status["progress"])  # 0-100
        >>> manager.cancel("abc123")
    """

    def __init__(self, reconstructor: Reconstructor, uploads_dir: str, outputs_dir: str, jobs_dir: str = None, model_dir: str = "backend/model", default_model_filename: str = "ConvNext_REAL-ESRGAN.pth", max_concurrent_jobs: int = 2):
        """Initialize the job manager.

        Args:
            reconstructor: Reconstructor instance for processing images.
            uploads_dir: Directory path containing uploaded input files.
            outputs_dir: Directory path where results will be saved.
            jobs_dir: Directory path where job metadata is persisted (optional).
            model_dir: Directory path containing model files.
            default_model_filename: Default model filename from config.
            max_concurrent_jobs: Maximum number of jobs that can run in parallel.
        """
        logger.info("Initializing JobManager")
        self.reconstructor = reconstructor
        self.uploads_dir = uploads_dir
        self.outputs_dir = outputs_dir
        self.jobs_dir = jobs_dir or str(Path(outputs_dir).parent / "jobs")
        self.model_dir = model_dir
        self.default_model_filename = default_model_filename
        self.max_concurrent_jobs = max_concurrent_jobs
        self._jobs: Dict[str, Dict] = {}
        self._lock = threading.Lock()
        self._running_count = 0

        # Create jobs directory if it doesn't exist
        Path(self.jobs_dir).mkdir(parents=True, exist_ok=True)

        # Load existing jobs from disk
        self._load_jobs()

        logger.info(f"JobManager initialized. Uploads: {uploads_dir}, Outputs: {outputs_dir}, Jobs: {self.jobs_dir}, Model dir: {model_dir}, Default model: {default_model_filename}")

    def _load_jobs(self):
        """Load all jobs from disk on startup."""
        logger.info("Loading persisted jobs from disk")
        jobs_path = Path(self.jobs_dir)
        loaded_count = 0

        for job_file in jobs_path.glob("*.json"):
            try:
                with open(job_file, "r") as f:
                    job_data = json.load(f)
                    job_id = job_data.get("job_id")
                    if job_id:
                        # Mark running jobs as failed on restart (they were interrupted)
                        if job_data.get("status") in ("queued", "running", "cancelling"):
                            job_data["status"] = "failed"
                            job_data["message"] = "interrupted by server restart"
                            job_data["error"] = "Server was restarted while job was processing"

                        self._jobs[job_id] = job_data
                        loaded_count += 1
                        logger.debug(f"Loaded job {job_id} with status {job_data['status']}")
            except Exception as e:
                logger.error(f"Failed to load job file {job_file}: {e}")

        logger.info(f"Loaded {loaded_count} jobs from disk")

    def _save_job(self, job_id: str):
        """Save a single job to disk.

        Snapshots the job metadata under the lock, then writes to disk outside the
        lock so file I/O does not block other threads.

        Args:
            job_id: Job identifier to save.
        """
        try:
            with self._lock:
                job_data = self._jobs.get(job_id)
                snapshot = dict(job_data) if job_data else None
            if snapshot is None:
                return
            job_file = Path(self.jobs_dir) / f"{job_id}.json"
            with open(job_file, "w") as f:
                json.dump(snapshot, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to save job {job_id} to disk: {e}")

    def _update(self, job_id: str, *, persist: bool = True, **kwargs):
        """Thread-safe update of job metadata.

        Args:
            job_id: Unique job identifier.
            persist: Whether to write the job to disk after updating. Pass False for
                high-frequency progress ticks to avoid a disk write on every percent.
            **kwargs: Job fields to update (status, progress, message, error, etc.).

        Note:
            This is an internal method and should not be called directly.
        """
        with self._lock:
            self._jobs[job_id].update(kwargs)
        # Persist to disk only when requested (status transitions), not every tick
        if persist:
            self._save_job(job_id)

    def prune_old(self, max_age_seconds: float) -> int:
        """Remove finished jobs older than max_age_seconds from memory and disk.

        Keeps the in-memory job table and persisted job files bounded over long
        uptime. Only jobs in a terminal state (completed/failed/cancelled) are
        removed; active jobs are always retained regardless of age.

        Args:
            max_age_seconds: Age threshold based on the job file's mtime.

        Returns:
            Number of jobs pruned.
        """
        cutoff = time.time() - max_age_seconds
        removed = 0
        jobs_path = Path(self.jobs_dir)
        with self._lock:
            for job_file in list(jobs_path.glob("*.json")):
                try:
                    if job_file.stat().st_mtime >= cutoff:
                        continue
                except OSError:
                    continue
                job_id = job_file.stem
                job = self._jobs.get(job_id)
                if job and job.get("status") not in ("completed", "failed", "cancelled"):
                    # Never prune an active job
                    continue
                try:
                    job_file.unlink()
                except OSError as e:
                    logger.error(f"Failed to delete job file {job_file}: {e}")
                    continue
                self._jobs.pop(job_id, None)
                removed += 1
        if removed:
            logger.info(f"Pruned {removed} old jobs from memory and disk")
        return removed

    def is_full(self) -> bool:
        """Check if the maximum number of concurrent jobs is reached.

        Returns:
            True if no more jobs can be accepted, False otherwise.
        """
        with self._lock:
            return self._running_count >= self.max_concurrent_jobs

    def enqueue(self, job_id: str, input_path: str, model_filename: str = None):
        """Create and enqueue a new reconstruction job.

        Creates a new job entry with initial metadata and starts a background worker
        thread to process it. The worker thread is daemonized and will be automatically
        terminated when the main program exits.

        Args:
            job_id: Unique identifier for this job (typically a UUID).
            input_path: Full path to the uploaded input image file.
            model_filename: Filename of the model to use (defaults to configured model).

        Raises:
            RuntimeError: If the maximum number of concurrent jobs is reached.

        Example:
            >>> manager.enqueue(
            ...     job_id="abc123",
            ...     input_path="/uploads/abc123_photo.png",
            ...     model_filename="REAL-ESRGAN.pth"
            ... )
        """
        if model_filename is None:
            model_filename = self.default_model_filename

        # Reject if at capacity
        with self._lock:
            if self._running_count >= self.max_concurrent_jobs:
                logger.warning(f"Job {job_id} rejected: {self._running_count}/{self.max_concurrent_jobs} slots in use")
                raise RuntimeError(f"max_concurrent:{self.max_concurrent_jobs}")
            self._running_count += 1

        logger.info(f"Enqueueing job {job_id}: {input_path} with model {model_filename} ({self._running_count}/{self.max_concurrent_jobs} slots)")
        with self._lock:
            self._jobs[job_id] = {
                "job_id": job_id,
                "status": "queued",
                "progress": 0,
                "message": "queued",
                "input_path": input_path,
                "output_path": str(Path(self.outputs_dir) / f"{job_id}.png"),
                "model_filename": model_filename,
                "cancel": False,
                "error": None,
                "start_time": None,
                "elapsed_seconds": None,
            }

        # Save job to disk immediately
        self._save_job(job_id)

        # Start background worker thread for this job
        t = threading.Thread(target=self._worker, args=(job_id,), daemon=True)
        t.start()
        logger.debug(f"Worker thread started for job {job_id}")

    def cancel(self, job_id: str) -> bool:
        """Request cancellation of a running or queued job.

        Sets the cancellation flag for the job. The worker thread will check this
        flag periodically and stop processing. Jobs that are already completed,
        failed, or cancelled cannot be cancelled.

        Args:
            job_id: Unique job identifier.

        Returns:
            True if cancellation was requested successfully, False if job not found
            or already finished.

        Example:
            >>> if manager.cancel("abc123"):
            ...     print("Cancellation requested")
            ... else:
            ...     print("Job not found or already finished")
        """
        logger.info(f"Cancel requested for job {job_id}")
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job["status"] in ("completed", "failed", "cancelled"):
                logger.warning(f"Cannot cancel job {job_id}: not found or already finished")
                return False
            job["cancel"] = True
            job["message"] = "cancelling"
            job["status"] = "cancelling"
            logger.info(f"Job {job_id} marked for cancellation")
        return True

    def get(self, job_id: str) -> Optional[Dict]:
        """Retrieve current job status and metadata.

        Returns a snapshot of the job's current state including status, progress,
        message, file paths, and any error information.

        Args:
            job_id: Unique job identifier.

        Returns:
            Dictionary containing job metadata, or None if job not found.
            Keys include: job_id, status, progress, message, input_path,
            output_path, cancel, error.

        Example:
            >>> job = manager.get("abc123")
            >>> if job:
            ...     print(f"Status: {job['status']}")
            ...     print(f"Progress: {job['progress']}%")
            ...     print(f"Message: {job['message']}")
        """
        with self._lock:
            job = self._jobs.get(job_id)
            if not job:
                return None
            return dict(job)

    def _worker(self, job_id: str):
        """Background worker thread that processes a single job.

        This method runs in a separate daemon thread for each job. It calls the
        reconstructor with progress and cancellation callbacks, and updates job
        status accordingly.

        Args:
            job_id: Unique job identifier to process.

        Note:
            This is an internal method called by enqueue() and should not be
            called directly.
        """
        logger.info(f"Worker starting for job {job_id}")

        def progress(pct: int, msg: str):
            """Progress callback to update job metadata (not persisted per tick)."""
            self._update(job_id, progress=pct, message=msg, persist=False)
            logger.debug(f"Job {job_id}: {pct}% - {msg}")

        def cancelled() -> bool:
            """Cancellation check callback."""
            with self._lock:
                return self._jobs[job_id].get("cancel", False)

        # Record start time
        start_time = time.time()
        self._update(job_id, status="running", message="starting", start_time=start_time)
        job = self.get(job_id)
        try:
            model_filename = job.get("model_filename", self.default_model_filename)
            logger.info(f"Job {job_id}: Using model '{model_filename}'")
            # Construct model path from filename using configured model directory
            model_path = Path(self.model_dir) / model_filename
            logger.debug(f"Model path: {model_path}")
            # Run the reconstruction process
            self.reconstructor.reconstruct(
                job["input_path"],
                job["output_path"],
                progress=progress,
                cancelled=cancelled,
                model_path=str(model_path)
            )
            # Calculate elapsed time
            elapsed = time.time() - start_time
            self._update(job_id, status="completed", message="completed", elapsed_seconds=round(elapsed, 2))
            logger.info(f"Job {job_id}: Completed successfully in {elapsed:.2f} seconds")
        except Cancelled:
            elapsed = time.time() - start_time
            self._update(job_id, status="cancelled", message="cancelled by user", elapsed_seconds=round(elapsed, 2))
            logger.info(f"Job {job_id}: Cancelled by user after {elapsed:.2f} seconds")
        except Exception as e:
            elapsed = time.time() - start_time
            # Store a generic, client-safe error; the full detail goes to the log only.
            self._update(job_id, status="failed", message="failed", error="Processing failed", elapsed_seconds=round(elapsed, 2))
            logger.error(f"Job {job_id}: Failed after {elapsed:.2f} seconds with error: {e}", exc_info=True)
        finally:
            with self._lock:
                self._running_count -= 1
            logger.info(f"Job {job_id}: Released slot ({self._running_count}/{self.max_concurrent_jobs} in use)")

