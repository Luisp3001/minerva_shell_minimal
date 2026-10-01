#!/usr/bin/env python3
import time
import numpy as np
from backend.core.live_session import LiveSession

def test_live_session_ws_and_latency():
    ls = LiveSession()
    assert ls.debug_latency is True
    assert ls._turn_count == 0

    # 1. Simular fin de habla por RMS
    fake_voice = (np.sin(np.linspace(0, 10, 1600)) * 2000).astype(np.int16).tobytes()
    ls._active = True
    ls.push_audio_chunk(fake_voice)
    assert ls._t_user_last_speech > 0

    # 2. Cola de WebSocket async
    assert ls._fish_async_queue is None

    # 3. Flexible play_queue unpacking
    # 2-tuple legacy/test format
    fake_audio = np.zeros(100, dtype=np.int16)
    ls._play_queue.put((fake_audio, 44100))
    assert ls._should_mute_mic_to_gemini()
    ls._play_queue.get()

    # 6-tuple with latency timestamps
    ls._play_queue.put((fake_audio, 44100, 0, time.monotonic(), time.monotonic(), time.monotonic()))
    assert ls._should_mute_mic_to_gemini()
    ls._play_queue.get()

    # 4. Barge-in resets state
    ls.is_speaking = True
    ls.barge_in()
    assert not ls.is_speaking
    assert ls._play_queue.empty()

    print("All live session WebSocket & latency tests passed!")

if __name__ == "__main__":
    test_live_session_ws_and_latency()
