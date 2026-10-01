#!/usr/bin/env python3
import sys
import time
import re
from backend.core.live_session import LiveSession

def test_live_session_logic():
    ls = LiveSession()
    assert not ls._should_mute_mic_to_gemini()
    
    # 1. Speaking mutes
    ls.is_speaking = True
    assert ls._should_mute_mic_to_gemini()
    ls.is_speaking = False
    assert not ls._should_mute_mic_to_gemini()
    
    # 2. Queue not empty mutes
    ls._play_queue.put((None, 16000))
    assert ls._should_mute_mic_to_gemini()
    ls._play_queue.get()
    assert not ls._should_mute_mic_to_gemini()
    
    # 3. Model turn mutes
    ls._in_model_turn = True
    assert ls._should_mute_mic_to_gemini()
    ls._in_model_turn = False
    assert not ls._should_mute_mic_to_gemini()
    
    # 4. Synthesizing mutes
    ls._is_synthesizing = True
    assert ls._should_mute_mic_to_gemini()
    ls._is_synthesizing = False
    assert not ls._should_mute_mic_to_gemini()
    
    # 5. Cooldown mutes
    ls._playback_cooldown_until = time.monotonic() + 1.0
    assert ls._should_mute_mic_to_gemini()
    ls._playback_cooldown_until = 0.0
    assert not ls._should_mute_mic_to_gemini()
    
    # 6. Barge in resets turn and cooldown
    ls._active = True
    ls.is_speaking = True
    ls._playback_cooldown_until = time.monotonic() + 1.0
    initial_turn_id = ls._current_turn_id
    ls.barge_in()
    assert ls._current_turn_id == initial_turn_id + 1
    assert not ls.is_speaking
    assert ls._playback_cooldown_until == 0.0
    assert not ls._should_mute_mic_to_gemini()

    # 7. Sentence splitting regex test
    sentence_regex = re.compile(r'([.!?]+(?:\s+|\Z)|[\n\r]+)')
    test_text = "[calm] Podríamos explorar temas como el impacto de la IA en la sociedad. ¿Te atrae"
    matches = list(sentence_regex.finditer(test_text))
    assert len(matches) == 1
    last_match = matches[-1]
    candidate = test_text[:last_match.end()].strip()
    remaining = test_text[last_match.end():]
    assert candidate == "[calm] Podríamos explorar temas como el impacto de la IA en la sociedad."
    assert remaining == "¿Te atrae"

    print("All tests passed successfully!")

if __name__ == "__main__":
    test_live_session_logic()
