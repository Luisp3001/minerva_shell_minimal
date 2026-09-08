#include "beattracker.hpp"
#include "audiocollector.hpp"
#include "audioprovider.hpp"
#include <aubio/aubio.h>
#include <cmath>

namespace caelestia::services {

BeatProcessor::BeatProcessor(QObject* parent)
    : AudioProcessor(parent)
    // 1. Cambiamos "default" por "specdiff" o "energy" que son más rápidos para transitorios de beats.
    // Reducir la ventana a 512 si ac::CHUNK_SIZE lo permite bajará drásticamente el lag.
    , m_tempo(new_aubio_tempo("complex", 1024, ac::CHUNK_SIZE, ac::SAMPLE_RATE))
    , m_in(new_fvec(ac::CHUNK_SIZE))
    , m_out(new_fvec(2)) {

    // Ajustar el umbral interno de Aubio para la detección de picos (silencio/ruido)
    if (m_tempo) {
        aubio_tempo_set_silence(m_tempo, -40.0f); // en dB
    }
}

BeatProcessor::~BeatProcessor() {
    if (m_tempo)
        del_aubio_tempo(m_tempo);
    if (m_in)
        del_fvec(m_in);
    if (m_out)
        del_fvec(m_out);
}

void BeatProcessor::process() {
    if (!m_tempo || !m_in)
        return;

    AudioCollector::instance().readChunk(m_in->data);

    // Evitamos el "return" agresivo por RMS para no romper la continuidad del buffer de Aubio.
    // Dejamos que el propio algoritmo gestione el umbral de silencio interno.
    aubio_tempo_do(m_tempo, m_in, m_out);

    if (m_out->data[0] != 0.0f) {
        // Obtenemos el delay detectado en segundos
        smpl_t delay = aubio_tempo_get_delay_s(m_tempo);
        emit beat(aubio_tempo_get_bpm(m_tempo), delay);
    }
}

BeatTracker::BeatTracker(QObject* parent)
    : AudioProvider(parent)
    , m_bpm(120.0f) {
    m_processor = new BeatProcessor();
    init();

    // Conectamos la nueva firma con el delay
    connect(static_cast<BeatProcessor*>(m_processor), &BeatProcessor::beat, this, &BeatTracker::updateBpm);
}

smpl_t BeatTracker::bpm() const {
    // Si Aubio devuelve valores locos (0 o negativos), retornamos un fallback seguro
    return (m_bpm > 0.0f) ? m_bpm : 120.0f;
}

void BeatTracker::updateBpm(smpl_t bpm, smpl_t delay) {
    if (bpm < 30.0f || bpm > 240.0f)
        return; // Filtro de rangos lógicos musicales

    // 2. En lugar de descartar drásticamente con un IF, usamos una Media Móvil Exponencial (EMA)
    // Esto suaviza las transiciones y se adapta rápido a cambios bruscos (como canciones rápidas)
    const float alpha = 0.3f; // Factor de suavizado (entre 0 y 1). Más alto = reacciona más rápido.
    smpl_t smoothedBpm = (alpha * bpm) + ((1.0f - alpha) * m_bpm);

    if (!qFuzzyCompare(smoothedBpm, m_bpm)) {
        m_bpm = smoothedBpm;
        emit bpmChanged();

        // Emitimos el golpe de beat hacia la interfaz
        // 'delay' te dice cuántos segundos atrás ocurrió el beat real en el buffer de audio.
        emit beat(m_bpm);
    }
}

} // namespace caelestia::services
