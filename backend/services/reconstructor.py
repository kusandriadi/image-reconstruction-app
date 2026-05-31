"""Image reconstruction service using PyTorch models.

This module provides the Reconstructor class for loading and running PyTorch models
to reconstruct images. It supports both CPU and CUDA execution, lazy model loading,
progress callbacks, and cancellation handling.
"""
from __future__ import annotations

import io
import logging
import os
import threading
from pathlib import Path
from typing import Callable, Optional

from PIL import Image

# Get logger
logger = logging.getLogger("image_reconstruction.reconstructor")

try:
    import torch
    TORCH_AVAILABLE = True
    logger.info("PyTorch is available")
except Exception as e:
    TORCH_AVAILABLE = False
    logger.warning(f"PyTorch is not available: {e}. Will use pass-through mode.")


class Reconstructor:
    """Image reconstruction engine using PyTorch models.

    This class handles loading and running PyTorch models for image reconstruction.
    It supports automatic device selection (CPU/CUDA), lazy model loading, progress
    tracking, and cancellation during processing.

    The model is loaded lazily on first use to avoid startup overhead. If PyTorch or
    the model file is not available, it falls back to pass-through mode (returns input).

    Attributes:
        model_path: Path to the PyTorch model file (.pt or .pth).
        model_loaded: Flag indicating if model has been loaded.
        model: Loaded PyTorch model instance (None if not loaded).
        device: Device being used for inference ('cpu' or 'cuda').

    Environment Variables:
        DEVICE: Force specific device ('cpu' or 'cuda'). Auto-detects if not set.

    Example:
        >>> reconstructor = Reconstructor(model_path="model.pth")
        >>> reconstructor.reconstruct(
        ...     input_path="input.png",
        ...     output_path="output.png",
        ...     progress=lambda pct, msg: print(f"{pct}%: {msg}")
        ... )
    """

    def __init__(self, model_path: str, device: str = "auto"):
        """Initialize the reconstructor with model path and device selection.

        Args:
            model_path: Path to the PyTorch model file (.pt or .pth format).
            device: Device to use for inference ("auto", "cpu", or "cuda").
                    Environment variable DEVICE overrides this value.
        """
        logger.info(f"Initializing Reconstructor with model path: {model_path}")
        self.model_path = str(model_path)
        self.model_loaded = False
        self.model: Optional[object] = None
        self._lock = threading.Lock()

        # Device selection: environment variable DEVICE > config device > auto-detect
        requested = os.getenv("DEVICE", device)
        if TORCH_AVAILABLE:
            if requested in ("cuda", "cpu"):
                if requested == "cuda" and not torch.cuda.is_available():
                    logger.warning("CUDA requested but not available, falling back to CPU")
                    self.device = "cpu"
                else:
                    self.device = requested
            else:
                self.device = "cuda" if torch.cuda.is_available() else "cpu"
        else:
            self.device = "cpu"

        logger.info(f"Device selected: {self.device} (requested: {requested})")

        # Check model availability on startup
        if not self.model_file_exists:
            logger.warning(f"MODEL NOT FOUND: {self.model_path} — reconstructions will fail until model is downloaded")

    @property
    def model_file_exists(self) -> bool:
        """Check if the configured model file exists on disk."""
        return Path(self.model_path).exists()

    @property
    def model_available(self) -> bool:
        """Check if model can be used for reconstruction (torch + file exist)."""
        return TORCH_AVAILABLE and self.model_file_exists

    def _lazy_load(self, progress: Optional[Callable[[int, str], None]] = None):
        """Lazily load the PyTorch model on first use.

        This method loads the model only when first needed, not during initialization.
        It tries to load the model on the configured device, falling back to CPU if
        loading fails. If PyTorch is not available or the model file doesn't exist,
        the reconstructor will operate in pass-through mode.

        Args:
            progress: Optional callback function(percent: int, message: str) for
                     reporting loading progress.

        Note:
            This method is called automatically by reconstruct() and should not be
            called directly.
        """
        if self.model_loaded:
            logger.debug("Model already loaded, skipping")
            return

        logger.info(f"Loading model: {self.model_path}")
        if progress:
            progress(5, "loading model")

        if TORCH_AVAILABLE and Path(self.model_path).exists():
            # Load model based on file extension
            try:
                logger.info(f"Loading model on device: {self.device}")
                if self.model_path.endswith(".pt"):
                    logger.debug("Loading TorchScript model (.pt)")
                    self.model = torch.jit.load(self.model_path, map_location=self.device)
                else:
                    logger.debug("Loading PyTorch model (.pth)")
                    # weights_only=True blocks arbitrary code execution via pickle
                    # when loading checkpoints (these are Real-ESRGAN state dicts).
                    loaded = torch.load(self.model_path, map_location=self.device, weights_only=True)

                    # Handle different checkpoint formats
                    if isinstance(loaded, dict):
                        logger.debug(f"Checkpoint keys: {list(loaded.keys())}")

                        # Try to extract the state dict from common checkpoint formats
                        state_dict = None
                        if 'params_ema' in loaded:
                            logger.info("Using 'params_ema' from checkpoint")
                            state_dict = loaded['params_ema']
                        elif 'params' in loaded:
                            logger.info("Using 'params' from checkpoint")
                            state_dict = loaded['params']
                        elif 'model' in loaded:
                            logger.info("Using 'model' from checkpoint")
                            self.model = loaded['model']
                        elif 'state_dict' in loaded:
                            logger.info("Using 'state_dict' from checkpoint")
                            state_dict = loaded['state_dict']
                        elif 'model_state_dict' in loaded:
                            logger.info("Using 'model_state_dict' from checkpoint")
                            state_dict = loaded['model_state_dict']
                        else:
                            # Assume the dict itself is the state dict
                            logger.info("Using dictionary as state_dict")
                            state_dict = loaded

                        # If we have a state dict, need to load it into a model architecture
                        if state_dict is not None:
                            from backend.models.rrdbnet_arch import RRDBNet
                            logger.info("Creating RRDBNet model architecture")
                            # Standard Real-ESRGAN configuration
                            self.model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                                               num_block=23, num_grow_ch=32, scale=4)
                            logger.debug(f"Loading state dict into model from: {self.model_path}")
                            self.model.load_state_dict(state_dict, strict=True)
                            logger.info(f"Model loaded successfully: {Path(self.model_path).name}")
                    else:
                        # Loaded object is already a model
                        logger.info("Checkpoint is a complete model")
                        self.model = loaded

                logger.info("Model loaded successfully")
            except Exception as e:
                logger.error(f"Failed to load model on {self.device}: {e}")
                import traceback
                logger.error(f"Traceback: {traceback.format_exc()}")
                # If loading fails, fall back to CPU attempt before giving up
                if self.device != "cpu":
                    try:
                        logger.info("Attempting to load model on CPU")
                        loaded = torch.load(self.model_path, map_location="cpu", weights_only=True)
                        if isinstance(loaded, dict) and 'params_ema' in loaded:
                            from backend.models.rrdbnet_arch import RRDBNet
                            self.model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                                               num_block=23, num_grow_ch=32, scale=4)
                            self.model.load_state_dict(loaded['params_ema'], strict=True)
                        elif isinstance(loaded, dict) and 'params' in loaded:
                            from backend.models.rrdbnet_arch import RRDBNet
                            self.model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                                               num_block=23, num_grow_ch=32, scale=4)
                            self.model.load_state_dict(loaded['params'], strict=True)
                        else:
                            self.model = loaded
                        self.device = "cpu"
                        logger.info("Model loaded successfully on CPU")
                    except Exception as e2:
                        logger.error(f"Failed to load model on CPU: {e2}")
                        logger.error(f"Traceback: {traceback.format_exc()}")
                        self.model = None
                else:
                    self.model = None

            # Set model to evaluation mode and move to device
            if hasattr(self.model, "eval"):
                logger.debug("Setting model to evaluation mode")
                self.model.eval()
            if hasattr(self.model, "to"):
                try:
                    logger.debug(f"Moving model to {self.device}")
                    self.model = self.model.to(self.device)
                except Exception as e:
                    logger.warning(f"Failed to move model to device: {e}")
                    # Keep as is if transfer fails
                    pass
        else:
            if not TORCH_AVAILABLE:
                logger.warning("PyTorch not available, using pass-through mode")
            elif not Path(self.model_path).exists():
                logger.warning(f"Model file not found: {self.model_path}, using pass-through mode")
            # Fallback: no real model, will use pass-through mode
            self.model = None

        if progress:
            progress(15, f"model ready on {self.device}")
        self.model_loaded = True
        logger.info(f"Model initialization complete. Mode: {'PyTorch' if self.model else 'Pass-through'}")

    def reconstruct(
        self,
        input_path: str,
        output_path: str,
        progress: Optional[Callable[[int, str], None]] = None,
        cancelled: Optional[Callable[[], bool]] = None,
        model_path: Optional[str] = None
    ):
        """Reconstruct an image using the loaded PyTorch model.

        This method processes an input image through the PyTorch model and saves
        the reconstructed result. It supports progress reporting and cancellation
        at various stages of processing.

        Processing stages:
        1. Model loading (0-15%)
        2. Reading input (15-20%)
        3. Preprocessing (20-35%)
        4. Model inference (35-70%)
        5. Writing output (70-90%)
        6. Done (90-100%)

        Args:
            input_path: Path to the input image file.
            output_path: Path where the reconstructed image will be saved.
            progress: Optional callback function(percent: int, message: str) for
                     reporting processing progress.
            cancelled: Optional callback function() -> bool that returns True if
                      processing should be cancelled.
            model_path: Optional path to a different model file to use for this
                       reconstruction. If provided and different from the current
                       model, the model will be reloaded.

        Raises:
            Cancelled: If the cancelled callback returns True during processing.
            IOError: If input file cannot be read.
            Exception: If model inference fails or output cannot be written.

        Example:
            >>> def track_progress(pct, msg):
            ...     print(f"Progress: {pct}% - {msg}")
            >>>
            >>> def is_cancelled():
            ...     return user_clicked_cancel
            >>>
            >>> reconstructor.reconstruct(
            ...     "input.jpg",
            ...     "output.png",
            ...     progress=track_progress,
            ...     cancelled=is_cancelled,
            ...     model_path="backend/model/REAL-ESRGAN.pth"
            ... )
        """
        def step(pct: int, msg: str):
            """Internal helper to report progress and check cancellation."""
            if progress:
                progress(pct, msg)
            if cancelled and cancelled():
                logger.info(f"Reconstruction cancelled for {input_path}")
                raise Cancelled()

        logger.info(f"Starting reconstruction: {input_path} -> {output_path}")

        # Only hold the lock while switching/loading the shared model. We then
        # capture a local reference to the loaded model and device so inference
        # runs WITHOUT serializing every job, and stays valid even if another
        # thread switches the model afterwards.
        with self._lock:
            # If a different model path is provided, reload the model
            if model_path and model_path != self.model_path:
                logger.info(f"Model switch: {self.model_path} -> {model_path}")
                self.model_path = model_path
                self.model_loaded = False
                self.model = None
            else:
                logger.info(f"Using model: {self.model_path}")

            # Load model lazily on first use
            self._lazy_load(progress)
            model = self.model
            device = self.device

        # Read and convert input image to RGB
        step(20, "reading input")
        logger.debug(f"Reading input image: {input_path}")
        img = Image.open(input_path).convert("RGB")
        logger.debug(f"Input image size: {img.size}")

        # Preprocess image into tensor
        step(35, "preprocessing")
        logger.debug("Preprocessing image to tensor")
        tensor = None
        T = None
        if TORCH_AVAILABLE:
            import torchvision.transforms as T  # type: ignore
            transform = T.Compose([T.ToTensor()])
            tensor = transform(img).unsqueeze(0)
            try:
                tensor = tensor.to(device)
                logger.debug(f"Tensor moved to {device}, shape: {tensor.shape}")
            except Exception as e:
                logger.warning(f"Failed to move tensor to device: {e}")
                # If device transfer fails, keep on CPU
                pass

        # Run model inference
        step(70, "running model")
        if TORCH_AVAILABLE and model is not None and tensor is not None:
            logger.info("Running model inference")
            with torch.no_grad():
                out = model(tensor)
            logger.debug("Model inference complete")
            # Normalize output into PIL Image
            if isinstance(out, (list, tuple)):
                out = out[0]
            if hasattr(out, "detach"):
                out = out.detach().cpu().squeeze(0)
            # Clamp values to [0, 1] range to prevent artifacts
            out = torch.clamp(out, 0, 1)
            logger.debug(f"Output tensor range: [{out.min():.4f}, {out.max():.4f}]")
            out_img = T.ToPILImage()(out)
            logger.debug(f"Output image size: {out_img.size}")
        else:
            # Fallback: no model available, return input image (pass-through)
            logger.info("Using pass-through mode (no model)")
            out_img = img

        # Save reconstructed image
        step(90, "writing output")
        logger.debug(f"Saving output to: {output_path}")
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        out_img.save(output_path, format="PNG")
        logger.info(f"Reconstruction complete: {output_path}")

        step(100, "done")


class Cancelled(Exception):
    """Exception raised when image reconstruction is cancelled by user.

    This exception is raised during reconstruction when the cancelled callback
    returns True, allowing graceful interruption of long-running operations.

    Example:
        >>> try:
        ...     reconstructor.reconstruct(..., cancelled=lambda: True)
        ... except Cancelled:
        ...     print("Reconstruction was cancelled")
    """
    pass
