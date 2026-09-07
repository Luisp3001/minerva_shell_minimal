#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AudioAnalyzer — Análisis de audio en tiempo real para la visualización del SiriOrb.

Calcula RMS (volumen) y 4 bandas de frecuencia (FFT) a partir de búferes PCM.
Los valores se normalizan a [0.0, 1.0] para uso directo como uniforms del shader.
"""
import numpy as np


class AudioAnalyzer:
    """Analiza chunks de audio PCM y retorna métricas visualizables."""

    # Rangos de frecuencia para las 4 bandas (Hz)
    BANDS = [
        (20,   80),    # band0: sub-bass
        (80,   300),   # band1: bass
        (300,  2000),  # band2: mids
        (2000, 8000),  # band3: highs
    ]

    def __init__(self, smoothing: float = 0.3):
        """
        Args:
            smoothing: Factor de suavizado exponencial (0=sin suavizado, 1=máximo).
                       Valores altos = más suave pero con más lag.
        """
        self._alpha = 1.0 - smoothing   # peso del valor nuevo
        self._rms   = 0.0
        self._bands = [0.0, 0.0, 0.0, 0.0]

    def analyze(self, pcm: np.ndarray, sample_rate: int) -> dict:
        """
        Analiza un chunk de audio PCM.

        Args:
            pcm: Array numpy de muestras de audio (int16 o float32).
                 Si es int16, se normaliza automáticamente a [-1.0, 1.0].
            sample_rate: Frecuencia de muestreo en Hz.

        Returns:
            dict con claves: rms, band0, band1, band2, band3 (todos float 0.0–1.0)
        """
        # Normalizar a float32 [-1.0, 1.0]
        if pcm.dtype == np.int16:
            samples = pcm.astype(np.float32) / 32768.0
        else:
            samples = pcm.astype(np.float32)

        if len(samples) == 0:
            return self._current_dict()

        # ── RMS (Root Mean Square → volumen) ─────────────────────────────
        rms_raw = float(np.sqrt(np.mean(samples ** 2)))
        # Voz humana típica tiene RMS ~0.05–0.3 en float32 normalizado.
        # Escalar ×4 para que el rango útil cubra [0.0, 1.0].
        rms_raw = min(1.0, rms_raw * 4.0)

        # Suavizado exponencial
        self._rms = self._rms * (1.0 - self._alpha) + rms_raw * self._alpha

        # ── FFT → 4 bandas de frecuencia ─────────────────────────────────
        n = len(samples)
        if n < 64:
            # Chunk demasiado pequeño para FFT significativa
            return self._current_dict()

        # Ventana Hann para reducir spectral leakage
        windowed = samples * np.hanning(n)
        fft_mag  = np.abs(np.fft.rfft(windowed))
        freqs    = np.fft.rfftfreq(n, d=1.0 / sample_rate)

        for i, (f_low, f_high) in enumerate(self.BANDS):
            mask = (freqs >= f_low) & (freqs < f_high)
            if np.any(mask):
                band_energy = float(np.mean(fft_mag[mask]))
                # Normalizar energía de banda a [0, 1]
                band_norm = min(1.0, band_energy / (n * 0.05))
                self._bands[i] = (
                    self._bands[i] * (1.0 - self._alpha) + band_norm * self._alpha
                )
            else:
                self._bands[i] *= (1.0 - self._alpha)

        return self._current_dict()

    def reset(self):
        """Resetea todos los valores suavizados a cero."""
        self._rms   = 0.0
        self._bands = [0.0, 0.0, 0.0, 0.0]

    def _current_dict(self) -> dict:
        """Retorna el estado actual como dict redondeado."""
        return {
            "rms":   round(self._rms, 4),
            "band0": round(self._bands[0], 4),
            "band1": round(self._bands[1], 4),
            "band2": round(self._bands[2], 4),
            "band3": round(self._bands[3], 4),
        }
