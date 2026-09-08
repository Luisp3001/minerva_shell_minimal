#pragma once

#include "audioprovider.hpp"
#include <aubio/aubio.h>
#include <qqmlintegration.h>

namespace caelestia::services {

class BeatProcessor : public AudioProcessor {
    Q_OBJECT

public:
    explicit BeatProcessor(QObject* parent = nullptr);
    ~BeatProcessor();

signals:
    // Enviamos tanto el BPM como el delay en segundos por si QML necesita ajustar timers
    void beat(smpl_t bpm, smpl_t delay);

protected:
    void process() override;

private:
    aubio_tempo_t* m_tempo;
    fvec_t* m_in;
    fvec_t* m_out;
};

class BeatTracker : public AudioProvider {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(smpl_t bpm READ bpm NOTIFY bpmChanged)

public:
    explicit BeatTracker(QObject* parent = nullptr);
    [[nodiscard]] smpl_t bpm() const;

signals:
    void bpmChanged();
    void beat(qreal bpm);

private:
    smpl_t m_bpm;
    void updateBpm(smpl_t bpm, smpl_t delay);
};

} // namespace caelestia::services
