import json
import re
import sys
from collections import Counter
from pathlib import Path


def send(**message):
    print(json.dumps(message), flush=True)


def suspicious(segments, token_limit):
    words = []
    for segment in segments:
        if len(segment.tokens) >= token_limit - 1 or segment.compression_ratio > 2.4:
            return True
        words.extend(re.findall(r"\w+", segment.text.casefold()))
    phrases = Counter(zip(words, words[1:], words[2:]))
    return any(count >= 3 for count in phrases.values())



def reduce_noise(audio, sample_rate):
    import av
    import numpy as np

    # Pad the tail so the filter can emit all speech despite its internal delay.
    padded = np.pad(audio, (0, sample_rate // 10))
    frame = av.AudioFrame.from_ndarray(padded.reshape(1, -1), format="flt", layout="mono")
    frame.sample_rate = sample_rate
    graph = av.filter.Graph()
    source = graph.add_abuffer(sample_rate=sample_rate, format="flt", layout="mono")
    denoiser = graph.add("afftdn", "nr=6:nf=-45:tn=1:gs=4")
    sink = graph.add("abuffersink")
    source.link_to(denoiser)
    denoiser.link_to(sink)
    graph.configure()
    graph.push(frame)
    graph.push(None)
    chunks = []
    while True:
        try:
            chunks.append(graph.pull().to_ndarray().reshape(-1))
        except av.error.EOFError:
            break
    return np.concatenate(chunks) if chunks else audio

def main():
    sys.path.insert(0, str(Path(__file__).resolve().with_name("packages")))
    import numpy as np
    from faster_whisper import WhisperModel
    from faster_whisper.audio import decode_audio

    sample_rate = 16_000
    model_dir = Path(sys.argv[1])
    fallback_dir = model_dir.with_name("model-fallback")
    has_fallback = (fallback_dir / "model.bin").is_file()
    model = WhisperModel(str(model_dir), device="cpu", compute_type="int8", cpu_threads=4)
    fallback = None
    translator = None

    def transcribe(engine, audio, **options):
        segments, _ = engine.transcribe(
            audio, language="en", task="transcribe", beam_size=3,
            without_timestamps=True, vad_filter=False,
            condition_on_previous_text=False, **options,
        )
        return list(segments)

    send(ready=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            path = Path(request["path"])
            terms = request.get("keyterms", [])
            audio = decode_audio(str(path), sampling_rate=sample_rate)
            if not audio.any():
                send(text="")
                continue
            # Keep the entire recording and provide 100 ms of leading context.
            audio = np.pad(audio, (sample_rate // 10, 0))
            token_limit = min(300, 24 + int(10 * len(audio) / sample_rate))
            if request.get("noise_reduction", False):
                try:
                    audio = reduce_noise(audio, sample_rate)
                except (ImportError, RuntimeError, ValueError, OSError) as error:
                    print(f"Noise filter unavailable: {type(error).__name__}", file=sys.stderr)
            if request.get("output_language") == "english":
                if translator is None:
                    translator = WhisperModel(str(model_dir.with_name("model-english")), device="cpu",
                                              compute_type="int8", cpu_threads=4, local_files_only=True)
                segments, _ = translator.transcribe(audio, language="te", task="translate",
                                                    beam_size=5, vad_filter=False,
                                                    condition_on_previous_text=False)
                send(text=" ".join(s.text.strip() for s in segments).strip())
                continue
            # Reserve space for Whisper's control tokens and generation limit.
            hints = []
            for term in terms:
                prompt = ", ".join([*hints, term])
                if len(model.hf_tokenizer.encode(" " + prompt).ids) <= model.max_length - token_limit - 6:
                    hints.append(term)
            hotwords = ", ".join(hints) or None
            options = dict(max_new_tokens=token_limit, temperature=0, no_repeat_ngram_size=4)
            segments = transcribe(model, audio, hotwords=hotwords, **options)
            if not any(seg.text.strip() for seg in segments) or suspicious(segments, token_limit):
                if has_fallback:
                    if fallback is None:
                        fallback = WhisperModel(str(fallback_dir), device="cpu", compute_type="int8", cpu_threads=4)
                    segments = transcribe(fallback, audio)
                elif hotwords:
                    segments = transcribe(model, audio, **options)
            send(text=" ".join(segment.text.strip() for segment in segments).strip())
        except Exception as error:
            send(error=str(error))


if __name__ == "__main__":
    main()
