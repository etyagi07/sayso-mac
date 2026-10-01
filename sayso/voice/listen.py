"""Speech capture and transcription, on whatever machine this is.

Recognition runs locally: MLX on Apple Silicon (fastest), faster-whisper
everywhere else. Both run the same OpenAI Whisper models; no audio leaves
the machine either way.

Microphone sensitivity is not a constant - it belongs to the computer and
the room, so it is read from config and set by `python -m voice.calibrate`.
"""

import sys

import numpy as np
import sounddevice as sd

from shoonya import profile
from voice import config, speak

SAMPLE_RATE = 16000          # what Whisper expects

R, G, DIM, X = "\033[91m", "\033[92m", "\033[2m", "\033[0m"

PROMPT = ("Index options and stock orders. Buy Nifty call. Buy Bank Nifty "
          "put fifty five six hundred. Buy Sensex call seventy four "
          "thousand. Exit the Sensex put. What is the Bank Nifty call at? "
          "Buy two lots of Nifty call twenty three one hundred. "
          "Buy one YESBANK. Stocks: RELIANCE, INFY, SBIN.")

_model = None


class NotCalibrated(RuntimeError):
    pass


def _threshold():
    value = config.get("silence_rms")
    if value is None:
        raise NotCalibrated(
            "This microphone has not been measured yet.\n"
            f"  Run: {profile.cmd('voice.calibrate')}"
        )
    return value


def _mlx_repo(name):
    return f"mlx-community/whisper-{name}-mlx"


# The exact model files every machine gets. Unpinned, each new install would
# fetch whatever was published last - a changed model changes what is heard.
MLX_REVISIONS = {"small.en": "52a88bf6e98b114a210c21bb83e22d6e1505cb73"}


def _mlx_path(name):
    """A local folder with the model at its pinned revision: from the cache
    when it is there, downloaded once when it is not."""
    repo, revision = _mlx_repo(name), MLX_REVISIONS.get(name)
    if revision is None:
        return repo                     # not pinned: mlx_whisper fetches it
    from huggingface_hub import snapshot_download
    try:
        return snapshot_download(repo_id=repo, revision=revision,
                                 local_files_only=True)
    except Exception:
        return snapshot_download(repo_id=repo, revision=revision)


# Download sizes, to say how big the one-time download is.
MLX_SIZES_MB = {"small.en": 481}


def download_mb():
    """The speech model's download size in MB if it still has to be
    downloaded on this machine, else None (already here, or unknown)."""
    if config.backend() != "mlx":
        return None
    name = config.get("asr_model")
    revision = MLX_REVISIONS.get(name)
    if revision is None:
        return None
    from huggingface_hub import snapshot_download
    try:
        snapshot_download(repo_id=_mlx_repo(name), revision=revision,
                          local_files_only=True)
        return None
    except Exception:
        return MLX_SIZES_MB.get(name)


def warm_up():
    """Load the recogniser once, so the first command is not slow."""
    global _model
    if _model is not None:
        return
    backend, name = config.backend(), config.get("asr_model")
    label = f"{backend}:{name}"
    print(f"{DIM}  loading speech model ({label})...{X}", end="", flush=True)

    if backend == "mlx":
        import mlx_whisper
        path = _mlx_path(name)
        mlx_whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32),
                               path_or_hf_repo=path)
        _model = ("mlx", path)
    else:
        from faster_whisper import WhisperModel
        # int8 runs acceptably on CPU, which is what non-Apple machines
        # will mostly be using here.
        _model = ("faster-whisper",
                  WhisperModel(name, device="auto", compute_type="int8"))
    print(f"\r{DIM}  speech model ready ({label}){' ' * 20}{X}")


def record_until_silence(on_level=None):
    """Record until the speaker stops. Returns float32 audio, or None.

    `on_level(x)`, if given, hears each 50 ms block's loudness relative to
    the silence threshold (1.0 = just loud enough to count as speech), for
    a level meter. It can never affect the recording.
    """
    threshold = _threshold()
    quiet_for = config.get("silence_seconds")
    cap = config.get("max_seconds")
    min_speech = config.get("min_speech_seconds")

    chunks, silent_for, spoke_for = [], 0.0, 0.0
    block = int(SAMPLE_RATE * 0.05)

    # Wait for any readback to finish, and hold announcements until the
    # recording is over - otherwise the app can hear itself as a command.
    with speak.listening(), sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="float32",
            blocksize=block, device=config.get("input_device")) as stream:
        print(f"  {R}* RECORDING{X} {DIM}(speak, then pause){X}",
              end="", flush=True)
        while True:
            data, _ = stream.read(block)
            mono = data[:, 0]
            chunks.append(mono.copy())

            rms = float(np.sqrt(np.mean(mono ** 2)))
            if on_level is not None:
                try:
                    on_level(rms / threshold)
                except Exception:
                    pass
            seconds = block / SAMPLE_RATE
            if rms < threshold:
                silent_for += seconds
            else:
                silent_for = 0.0
                spoke_for += seconds

            if spoke_for >= min_speech and silent_for >= quiet_for:
                break
            if len(chunks) * seconds >= cap:
                break

    print(f"\r  {DIM}o processing...{' ' * 25}{X}", end="", flush=True)
    audio = np.concatenate(chunks) if chunks else np.zeros(1, dtype=np.float32)
    return audio if spoke_for >= min_speech else None


def transcribe(audio):
    warm_up()
    kind, handle = _model
    if kind == "mlx":
        import mlx_whisper
        result = mlx_whisper.transcribe(audio, path_or_hf_repo=handle,
                                        language="en", initial_prompt=PROMPT)
        return (result.get("text") or "").strip()

    segments, _ = handle.transcribe(audio, language="en",
                                    initial_prompt=PROMPT, beam_size=1)
    return " ".join(s.text for s in segments).strip()


def listen_once():
    """Record, transcribe. Returns the transcript, or None."""
    audio = record_until_silence()
    if audio is None:
        print(f"\r  {DIM}o nothing heard{' ' * 25}{X}")
        return None
    text = transcribe(audio)
    print(f"\r{' ' * 50}\r", end="")
    return text or None


if __name__ == "__main__":
    try:
        warm_up()
    except NotCalibrated as e:
        print(f"{R}{e}{X}")
        sys.exit(1)
    print(f"\n{G}* READY{X} {DIM}press Enter to speak, ctrl-c to quit{X}")
    while True:
        try:
            input()
            said = listen_once()
            print(f"  heard: {said!r}" if said else f"  {DIM}(silence){X}")
        except KeyboardInterrupt:
            print(f"\n{DIM}o stopped{X}")
            sys.exit(0)
