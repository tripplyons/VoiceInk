# Voice isolation and normalization

RNNoise runs locally at 48 kHz with its bundled model. The Swift package is
pinned to `9bb6d4c4971a8594f9306cdb1acb6b4013b6ef05`.

Microphone processing order is downmix, band-limited resampling to 48 kHz,
RNNoise with breath-detail retention, microphone EQ, lookahead speech leveling,
then band-limited resampling to 16 kHz. Recorded PCM and streaming chunks use
the same output. Do not process recordings again when they stop.

Factory defaults match the user's selected settings: RNNoise off (0%), Linear
blending, 100% normalization, and enabled flat EQ with a 300 Hz high-pass and
7.9 kHz low-pass. Saved custom settings are not overwritten. Audio Setup reset
buttons restore these defaults. With RNNoise off, breathy detail is not removed
by the denoiser, but its noise suppression and speech-confidence guard are also
inactive.

A local whisper-sample comparison at 3, 6, and 7.8 kHz recovered the same words.
Wider filtering retained more high-frequency signal; this establishes no formal
recognition-accuracy improvement. The selected 7.9 kHz default is a user preference.

At 0%, RNNoise is bypassed. At 100%, it emits the full denoised signal.
Intermediate blends retain a bounded extra portion (at most 20%) of the removed
high-frequency detail near detected speech, with a short release for unvoiced
consonants. The detail filter starts around 1.5 kHz; it does not restore room
rumble. This is not a guarantee that every breathy phoneme survives.
Equal-power blending may raise midpoint loudness because dry and wet signals
are correlated.

## Timing

The pinned RNNoise model delays output by two 10 ms frames. Its wrapper aligns
the original signal with that delay, discards startup output, and flushes the
last frames before closing. Resamplers retain fractional phase between chunks.

Normalization buffers a complete lookahead frame, measures and filters it once,
then applies the measured correction from the first sample of that frame.
Lookahead defaults to 10 ms and is configurable from 5 to 100 ms. It adds that
buffering delay but does not add leading silence or change the frame count.
Partial final frames are analyzed and emitted without zero padding.

The startup ramp defaults to 100 ms and is configurable from 1 to 100 ms. Its
exponential response reaches about 99% of the first target gain within the
selected duration. This avoids a fixed starting boost or a one-sample jump.
Timings are validated and snapshotted per recording/import, included in backups,
and shared across channels so stereo balance is preserved.

Without isolation, amplitude-based gain remains unrestricted. With isolation,
RNNoise confidence selects which frames can update the level estimate.
Unsupported frames cannot teach the leveler to treat the room noise floor as
quieter speech. Learned correction holds across weak phonemes and short pauses,
then returns to neutral as confidence decays. Rumble filtering and transient
protection remain active even with adaptive strength at zero.

RNNoise suppresses background noise, not overlapping speakers. Synthetic tests
verify timing, suppression, and detail retention, not intelligibility. Sample
comparisons use cached local Parakeet models without uploading audio. No exact
reference transcript was supplied, so they establish no formal word-error rate.
