"""The M0 ASR backend (D5).

Split deliberately: everything that can be checked without MLX is checked
without it, because invariant 4 says text-only mode is fully functional and CI
runs on Linux where MLX cannot install. Only the tests that genuinely need
Apple Silicon are skipped, and they are skipped rather than deleted so that
running the suite on a Mac says something the Linux run cannot.
"""

import json

import pytest

from cochlea import asr

needs_mlx = pytest.mark.skipif(not asr.available(),
                               reason="mlx-whisper is not installed (Apple Silicon only)")


# --- importable without MLX --------------------------------------------------

def test_module_imports_without_an_asr_backend():
    """Invariant 4. The import graph is the easiest place to break it."""
    assert isinstance(asr.available(), bool)
    assert asr.SAMPLE_RATE == 16_000


def test_describe_names_the_extra_when_absent():
    text = asr.describe()
    assert isinstance(text, str) and text


# --- the model directory contract -------------------------------------------
#
# The app downloads and checksum-verifies the weights (F21, D4) and hands over
# a directory. These check that a directory which is wrong fails with a
# sentence naming the fix, rather than deep inside a loader.

def test_a_missing_directory_names_the_first_run_download(tmp_path):
    with pytest.raises(asr.ASRUnavailable) as exc:
        asr.verify_model_directory(tmp_path / "absent")
    assert "first run" in str(exc.value)


def test_a_directory_without_a_config_is_refused(tmp_path):
    (tmp_path / "weights.safetensors").write_bytes(b"")
    with pytest.raises(asr.ASRUnavailable) as exc:
        asr.verify_model_directory(tmp_path)
    assert "config.json" in str(exc.value)


def test_a_directory_without_weights_is_refused(tmp_path):
    (tmp_path / "config.json").write_text("{}")
    with pytest.raises(asr.ASRUnavailable) as exc:
        asr.verify_model_directory(tmp_path)
    assert "weights" in str(exc.value)


@pytest.mark.parametrize("weights", ["weights.safetensors", "weights.npz"])
def test_both_weight_layouts_are_accepted(tmp_path, weights):
    """large-v3-turbo ships safetensors; whisper-small ships npz."""
    (tmp_path / "config.json").write_text("{}")
    (tmp_path / weights).write_bytes(b"")
    assert asr.verify_model_directory(tmp_path) == tmp_path


def test_the_required_files_match_what_the_downloader_fetches():
    """ModelResolver.isNeeded and mlx_whisper.load_model must agree.

    If they drift, the app downloads a directory the loader cannot read, and
    the failure lands at first use rather than at download time.
    """
    assert set(asr.REQUIRED_FILES) == {"config.json"}
    assert set(asr.WEIGHT_FILES) == {"weights.safetensors", "weights.npz"}


# --- needs the real thing ----------------------------------------------------

@needs_mlx
def test_fp16_is_the_default(tmp_path):
    """Measured at roughly 2x wall clock against fp32 (D6), against a 1s budget."""
    (tmp_path / "config.json").write_text("{}")
    (tmp_path / "weights.npz").write_bytes(b"")
    assert asr.MLXWhisperBackend(tmp_path).fp16 is True


@needs_mlx
def test_identifier_defaults_to_the_directory_name(tmp_path):
    (tmp_path / "config.json").write_text("{}")
    (tmp_path / "weights.npz").write_bytes(b"")
    assert asr.MLXWhisperBackend(tmp_path).identifier == tmp_path.name
    assert asr.MLXWhisperBackend(tmp_path, identifier="x").identifier == "x"
