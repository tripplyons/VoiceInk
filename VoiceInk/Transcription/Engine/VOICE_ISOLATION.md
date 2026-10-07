# Voice isolation

RNNoise runs locally at 48 kHz with its bundled model. The Swift package is
pinned to `9bb6d4c4971a8594f9306cdb1acb6b4013b6ef05`.

Microphone processing order is downmix, band-limited resampling to 48 kHz,
RNNoise, microphone EQ, speech leveling, then band-limited resampling to 16 kHz.
Recorded PCM and streaming chunks use the same output. Recorded audio must not
be processed a second time when recording stops.

Imports use isolation before normalization. Multichannel files retain a shared
normalization gain. Voice isolation strength defaults to 35%, with Linear
blending. Normalization defaults to 100% correction. These defaults preserve
more unvoiced whisper detail than full noise suppression. Saved custom strengths
are not overwritten; the Audio Setup reset buttons restore factory values. At 0%, RNNoise is bypassed. Equal-power blending may raise midpoint
loudness because the original and denoised signals are correlated.

The pinned RNNoise model delays output by two 10 ms frames. The wrapper aligns
the original signal with that delay, removes startup output, and flushes the
last frames before closing. Resamplers retain fractional phase between chunks.

Normalization keeps unrestricted amplitude-based correction without isolation.
With isolation, RNNoise confidence selects which fixed 20 ms frames can update
the level estimate. Unsupported frames cannot teach the leveler to treat the
room noise floor as quieter speech. The last learned correction is held across
weak phonemes and short pauses, then returns to neutral as confidence decays.
Confidence still scales upward correction on supported frames, rather than
turning every weak syllable into a smaller correction.

The first usable analysis frame starts a fast acquisition ramp (3 ms time
constant, active for 20 ms). This brings quiet speech up sooner than the normal
50 ms recovery ramp without a fixed starting boost or a one-sample gain jump.
Gain remains unrestricted by amplitude thresholds or gain caps. Rumble filtering
and transient protection remain active.

RNNoise suppresses background noise, not overlapping speakers. Quality still
needs listening checks on real microphones and transcription checks on real
speech. Synthetic noise tests measure suppression, not intelligibility.
